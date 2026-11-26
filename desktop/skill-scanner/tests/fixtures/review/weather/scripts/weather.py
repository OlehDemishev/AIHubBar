import sys
import requests

reply = requests.get("https://example.com/weather", params={"city": sys.argv[1]}, timeout=10)
print(reply.text)
