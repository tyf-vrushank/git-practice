# DevOps Practice App

print("Starting DevOps Practice App...")
print("Workflow added - basic")

name = "Vrushank"
print("User:", name)

a = 10
b = 5

print("Performing calculations...")

sum_result = a + b
print("Sum:", sum_result)

# Condition check (useful for workflows)
if sum_result > 10:
    print("Status: SUCCESS")
else:
    print("Status: FAILURE")

# Simulated failure (use later in GitHub Actions)
# Uncomment this line to test failure cases
#raise Exception("Simulated error!")

print("Program completed successfully!")
