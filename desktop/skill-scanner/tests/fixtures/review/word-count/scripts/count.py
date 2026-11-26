import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(handle.read().split()))
