# =============================================================================
# OpenVAS / GVM Community Edition – EKS Helm Deployment
# Path: environments/nonprod/us-west-2/openvas/eks-helm/terragrunt.hcl
#
# Helm chart: admirito/gvm  (github.com/admirito/gvm-containers)
#   - This is the most battle-tested, K8s-native GVM CE chart available.
#   - The "greenbone" official chart repo referenced by many AI tools does NOT
#     host a stable, publicly installable CE chart – do not use that URL.
#   - Chart is consumed directly from the GitHub release tarball URL (OCI-less,
#     works with aws-duplo-helm module the same way any https:// chart URL does).
#
# Chart version pinned to 1.3.0 (latest stable as of 2025-Q1).
# Update ref in `repository_url` when you want to upgrade.
#
# SECRETS: gvmdPassword MUST be rotated before prod.  Store it in AWS Secrets
# Manager or DuploCloud Secrets and reference via your secret-injection pattern
# (see the TODO comments below).
# =============================================================================

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git@github.com:TyfoneInc/devops-terragrunt-aws//tf_modules/aws-duplo-helm?ref=main"
}

# ---------------------------------------------------------------------------
# Dependency: openvas tenant
# The openvas tenant must exist in DuploCloud before this runs.
# Folder: environments/nonprod/us-west-2/openvas/
# ---------------------------------------------------------------------------
dependency "tenant" {
  config_path = "../../"
  mock_outputs = {
    tenant_name = "openvas"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# ---------------------------------------------------------------------------
# Local values – change these per environment, not buried in the values block
# ---------------------------------------------------------------------------
locals {
  environment   = "nonprod"
  cluster_name  = "duploinfra-nonprod"   # update for prod: "duploinfra-prod"
  region        = "us-west-2"
  ingress_host  = "openvas.nonprod.internal.tyfone.com"  # internal DNS; flip to public FQDN if needed

  # Pinned chart release – always pin, never use "latest" in infra-as-code.
  # Check for new releases at:
  # https://github.com/admirito/gvm-containers/releases
  chart_version = "1.3.0"
  chart_url     = "https://github.com/admirito/gvm-containers/releases/download/chart-${local.chart_version}/gvm-${local.chart_version}.tgz"

  # Storage class that exists on your EKS cluster.
  # DuploCloud typically provisions "gp2" or "gp3".  Confirm with:
  #   kubectl get storageclass
  storage_class = "gp3"

  # TODO: Replace plaintext password before prod.
  # Pattern: pull from AWS Secrets Manager via a data source or
  # use DuploCloud's secret injection, then reference here as:
  #   gvmd_password = data.aws_secretsmanager_secret_version.openvas.secret_string
  gvmd_username = "admin"
  gvmd_password = "CHANGE_ME_BEFORE_PROD"  # ← rotate this

  # PostgreSQL password for the gvmd backing database
  gvmd_db_password = "CHANGE_ME_BEFORE_PROD"  # ← rotate this
}

# ---------------------------------------------------------------------------
# Main inputs
# ---------------------------------------------------------------------------
inputs = {
  tenant_name = dependency.tenant.outputs.tenant_name

  helm_releases = {

    openvas-gvm = {
      # -----------------------------------------------------------------------
      # Release identity
      # -----------------------------------------------------------------------
      name = "openvas-gvm"

      # aws-duplo-helm supports a full https:// URL as the chart source.
      # The module treats any value starting with "https://" as a chart URL
      # rather than a chart name from a repo – no repository_url needed in
      # that case.  Adjust if your module version requires explicit repo fields.
      chart_name      = local.chart_url
      chart_version   = local.chart_version   # informational; URL is the source of truth
      repository_name = ""                    # not used when chart_name is a URL
      repository_url  = ""                    # not used when chart_name is a URL

      # -----------------------------------------------------------------------
      # Helm values (jsonencode mirrors the Datadog pattern in your codebase)
      # -----------------------------------------------------------------------
      values = jsonencode({

        # -------------------------------------------------------------------
        # GLOBAL
        # -------------------------------------------------------------------
        global = {
          # If your DuploCloud ECR mirror is configured, swap in:
          # imageRegistry = "123456789.dkr.ecr.us-west-2.amazonaws.com"
          imageRegistry = ""
        }

        # -------------------------------------------------------------------
        # GVMD (Greenbone Vulnerability Manager Daemon)
        # Core orchestration service – moderate CPU, high memory at scan time.
        # -------------------------------------------------------------------
        gvmd = {
          image = {
            registry   = "docker.io"
            repository = "admirito/gvmd"
            tag        = "22"            # GVM 22.x LTS; bump when upstream releases 23.x stable
            pullPolicy = "IfNotPresent"
          }

          resources = {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"   # scans are CPU-bursty; allow headroom
              memory = "3Gi"
            }
          }

          # Feed sync cron – daily NVT/CERT/SCAP refresh
          # Runs as a Kubernetes CronJob; adjust schedule for your timezone
          feedSync = {
            enabled  = true
            schedule = "0 2 * * *"   # 02:00 UTC daily
          }
        }

        # -------------------------------------------------------------------
        # OPENVAS SCANNER
        # The actual scanning engine – CPU-heavy during active scans.
        # -------------------------------------------------------------------
        openvas = {
          image = {
            registry   = "docker.io"
            repository = "admirito/openvas"
            tag        = "22"
            pullPolicy = "IfNotPresent"
          }

          resources = {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"   # scanning is CPU-bursty
              memory = "2Gi"
            }
          }
        }

        # -------------------------------------------------------------------
        # GSAD (Greenbone Security Assistant – the web UI)
        # Lightweight proxy; minimal resource footprint.
        # -------------------------------------------------------------------
        gsad = {
          image = {
            registry   = "docker.io"
            repository = "admirito/gsad"
            tag        = "22"
            pullPolicy = "IfNotPresent"
          }

          resources = {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          # GSAD listens on 9392 by default inside the container.
          service = {
            type = "ClusterIP"
            port = 9392
          }
        }

        # -------------------------------------------------------------------
        # SECRETS – admin credentials
        # The chart creates a K8s Secret from these values.
        # TODO: Replace with a secretsManager reference pattern for prod.
        # -------------------------------------------------------------------
        secrets = {
          existingSecret = ""   # set to your K8s secret name to skip chart-managed secret
          gvmdUsername   = local.gvmd_username
          gvmdPassword   = local.gvmd_password
        }

        # -------------------------------------------------------------------
        # PERSISTENCE
        # Shared PVC carries NVT plugins between gvmd and the openvas scanner.
        # ReadWriteOnce is sufficient for single-node dev; for multi-node you
        # need a ReadWriteMany (EFS) storage class.
        # -------------------------------------------------------------------
        persistence = {
          enabled       = true
          existingClaim = ""
          accessMode    = "ReadWriteOnce"
          storageClass  = local.storage_class
          size          = "30Gi"   # NVT feed + scan results; 20 Gi fills up fast
        }

        # -------------------------------------------------------------------
        # DATABASE (gvmd-db sub-chart – PostgreSQL)
        # -------------------------------------------------------------------
        "gvmd-db" = {
          image = {
            registry   = "docker.io"
            repository = "admirito/gvm-postgres"
            tag        = "20"
          }

          postgresqlPassword = local.gvmd_db_password

          persistence = {
            enabled      = true
            storageClass = local.storage_class
            size         = "20Gi"
          }

          resources = {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          # Security contexts – required if your EKS node group enforces PSPs/PSA
          volumePermissions = {
            enabled = false
          }
          securityContext = {
            enabled = false
          }
        }

        # -------------------------------------------------------------------
        # REDIS (openvas-redis sub-chart)
        # Scan task queue between gvmd and openvas-scanner.
        # -------------------------------------------------------------------
        "openvas-redis" = {
          master = {
            persistence = {
              enabled      = true
              storageClass = local.storage_class
              size         = "5Gi"
            }
            resources = {
              requests = {
                cpu    = "100m"
                memory = "128Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "512Mi"
              }
            }
          }
        }

        # -------------------------------------------------------------------
        # INGRESS
        # Internal-only ingress is the safe default for a scanner.
        # Set annotations to match your ALB / nginx ingress controller.
        # For ALB (DuploCloud default):
        #   kubernetes.io/ingress.class: alb
        #   alb.ingress.kubernetes.io/scheme: internal
        # -------------------------------------------------------------------
        ingress = {
          enabled = true

          annotations = {
            "kubernetes.io/ingress.class"                = "alb"
            "alb.ingress.kubernetes.io/scheme"           = "internal"       # NEVER internet-facing for a scanner
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/healthcheck-path" = "/login"
            # Uncomment to force HTTPS:
            # "alb.ingress.kubernetes.io/listen-ports"  = "[{\"HTTPS\": 443}]"
            # "alb.ingress.kubernetes.io/certificate-arn" = "arn:aws:acm:us-west-2:ACCOUNT:certificate/CERT_ID"
          }

          hosts = [
            {
              host  = local.ingress_host
              paths = ["/"]
            }
          ]

          tls = []   # populate for prod: [{secretName = "openvas-tls", hosts = [local.ingress_host]}]
        }

        # -------------------------------------------------------------------
        # FEED SYNC (post-install / cron)
        # Setting syncFeedsAfterInstall = true triggers a Helm hook that
        # syncs feeds before the chart is marked ready.  Takes ~60-90 min on
        # first run.  Set to false for faster POC iteration; run sync manually
        # from the OpenVAS UI instead.
        # -------------------------------------------------------------------
        syncFeedsAfterInstall = false   # flip to true for a production-ready baseline

        # -------------------------------------------------------------------
        # NODE SCHEDULING
        # Pin the scanner to nodes that can support heavy CPU bursts.
        # Adjust the label selector to match your node group labels.
        # -------------------------------------------------------------------
        nodeSelector = {}
        # Example to pin to a dedicated security node group:
        # nodeSelector = {
        #   "role" = "security-scanner"
        # }

        tolerations = [
          {
            operator = "Exists"   # match Datadog pattern; tolerates all taints
          }
        ]

        affinity = {}   # add pod anti-affinity here if you run replicated GSAD in prod
      })
    }
  }
}

# =============================================================================
# NEXT STEPS AFTER APPLY
# =============================================================================
# 1. Verify pods:
#      kubectl get pods -n duploservices-openvas
#
# 2. First-time feed sync (takes ~60-90 min):
#      kubectl exec -n duploservices-openvas deploy/openvas-gvm-gvmd \
#        -- gvmd --rebuild --progress
#    Or trigger from the OpenVAS UI: Administration → Feed Status → Update.
#
# 3. Access the UI:
#      kubectl port-forward -n duploservices-openvas svc/openvas-gvm-gsad 9392:9392
#      open https://localhost:9392
#    Or via the ALB internal URL once DNS propagates.
#
# 4. Create targets for your POC endpoints:
#      https://mb-devnfin.cloud.tyfone.com
#      https://mb-devnfin.cloud.tyfone.com/adminconsole
#      https://mb-devnfin.cloud.tyfone.com/bankingapiserver
#
# 5. Run a scan: Configuration → Targets → New Target → add URL(s)
#              Scans → Tasks → New Task → assign target → Start
#
# 6. BEFORE PROD: rotate gvmd_password + gvmd_db_password via AWS Secrets Manager.
# =============================================================================
