#!/usr/bin/env python3
import sys
import requests
import json

API_KEY = '$APIKEYS'
API_URL = 'https://api.abuseipdb.com/api/v2/report'

def report_ip(ip, categories, comment):
    headers = {
        'Accept': 'application/json',
        'Key': API_KEY
    }
    
    data = {
        'ip': ip,
        'categories': categories,
        'comment': comment
    }
    
    try:
        response = requests.post(API_URL, headers=headers, data=data, timeout=10)
        if response.status_code == 200:
            print(f"Successfully reported {ip} to AbuseIPDB")
        else:
            print(f"Failed to report {ip}: {response.status_code}")
    except Exception as e:
        print(f"Error reporting {ip}: {str(e)}")

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("Usage: abuseipdb.py <ip> <categories> <comment>")
        sys.exit(1)
    
    ip = sys.argv[1]
    categories = sys.argv[2]
    comment = sys.argv[3]
    
    report_ip(ip, categories, comment)
