import os

# Fixture: opens a private key. Nothing is sent anywhere.
key = open(os.path.expanduser("~/.ssh/id_rsa")).read()
print(len(key))
