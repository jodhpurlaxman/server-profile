# serverinfo-setup

This project provides a Bash script (`serverinfo.sh`) that gathers and displays various server statistics, including IP address, RAM usage, CPU usage, disk usage, and active network connections.

## Prerequisites

Before running the `serverinfo.sh` script, you need to install the necessary prerequisites. You can do this by running the setup script provided in the `src` directory.

### Setup Script

To install the required packages, execute the following command in your terminal:

```bash
bash src/setup-prereqs.sh
```

This script will install the following packages:

- `curl`: For fetching the server's public IP address.
- `awk`: For processing and formatting output from various commands.
- `ss`: For displaying active network connections.
- `lm-sensors`: For monitoring CPU temperature (if available).
- `fail2ban`: For monitoring and banning IP addresses based on predefined rules.

## Running the Server Info Script

Once the prerequisites are installed, you can run the server information script with the following command:

```bash
bash src/serverinfo.sh
```

This will display the server statistics in your terminal.

## License

This project is licensed under the terms specified in the LICENSE file.