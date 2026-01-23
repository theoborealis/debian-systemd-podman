#!/usr/bin/env python3
"""
netavark wrapper for gVisor: fakes bridge network setup/teardown.

Under gVisor, netlink operations needed for bridge/veth creation are not
supported. Since all containers use host networking (network namespace is
removed by crun-gvisor wrapper), we just need to return valid responses
with the host's DNS servers so containers can resolve names.

The crun-gvisor wrapper removes the network namespace from the OCI config,
so containers actually share the host network regardless of what network
podman thinks they're on. This wrapper ensures podman's network management
layer is satisfied without performing any real network operations.
"""
import json
import sys
import os


def get_args():
    """Parse netavark CLI arguments."""
    args = sys.argv[1:]
    command = None
    ns_path = None
    config_file = None
    i = 0
    while i < len(args):
        if args[i] in ("setup", "teardown", "update", "version"):
            command = args[i]
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                ns_path = args[i + 1]
                i += 1
        elif args[i] in ("-f", "--file"):
            if i + 1 < len(args):
                config_file = args[i + 1]
                i += 1
        i += 1
    return command, ns_path, config_file


def get_host_dns():
    """Read DNS servers from the host's resolv.conf."""
    servers = []
    try:
        with open("/etc/resolv.conf") as f:
            for line in f:
                if line.strip().startswith("nameserver"):
                    srv = line.strip().split()[1]
                    servers.append(srv)
    except (IOError, IndexError):
        pass
    return servers or ["169.254.1.1"]


def read_input(config_file):
    """Read network config from file or stdin."""
    if config_file:
        with open(config_file) as f:
            return json.load(f)
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return {}


def handle_setup(config_file):
    """Return fake setup response with host DNS servers.

    Input format (from podman):
    {
        "container_id": "...",
        "networks": {"net_name": {"static_ips": [...], "interface_name": "eth0"}},
        "network_info": {"net_name": {"subnets": [{"subnet": "...", "gateway": "..."}]}}
    }

    Output format (expected by podman):
    {
        "net_name": {
            "interfaces": {"eth0": {"mac_address": "...", "subnets": [...]}},
            "dns_server_ips": [...],
            "dns_search_domains": []
        }
    }
    """
    config = read_input(config_file)
    networks = config.get("networks", {})
    network_info = config.get("network_info", {})
    dns_servers = get_host_dns()

    response = {}
    for net_name, net_opts in networks.items():
        info = network_info.get(net_name, {})
        subnets = info.get("subnets", [])
        iface_name = net_opts.get("interface_name", "eth0")
        static_ips = net_opts.get("static_ips", [])

        gateway = "10.88.0.1"
        container_ip = "10.88.0.2"
        prefix = "24"

        if subnets:
            subnet = subnets[0]
            gateway = subnet.get("gateway", gateway)
            sub = subnet.get("subnet", "")
            if "/" in sub:
                prefix = sub.split("/")[1]

        if static_ips:
            container_ip = static_ips[0]
        elif gateway:
            parts = gateway.rsplit(".", 1)
            container_ip = parts[0] + ".2"

        response[net_name] = {
            "interfaces": {
                iface_name: {
                    "mac_address": "02:42:0a:58:00:02",
                    "subnets": [{
                        "ipnet": container_ip + "/" + prefix,
                        "gateway": gateway
                    }]
                }
            },
            "dns_server_ips": dns_servers,
            "dns_search_domains": []
        }

    json.dump(response, sys.stdout)


def handle_teardown(config_file):
    """Teardown is a no-op since we never created real interfaces."""
    read_input(config_file)
    print("{}")


def main():
    command, ns_path, config_file = get_args()

    if command == "setup":
        handle_setup(config_file)
    elif command == "teardown":
        handle_teardown(config_file)
    elif command == "version":
        real = "/usr/lib/podman/netavark.real"
        if os.path.exists(real):
            os.execv(real, sys.argv)
        print(json.dumps({"version": "1.0.0-gvisor"}))
    elif command == "dhcp-proxy":
        # dhcp-proxy is a long-running service, just exit cleanly
        sys.exit(0)
    else:
        # For unknown commands, try the real netavark
        real = "/usr/lib/podman/netavark.real"
        if os.path.exists(real):
            os.execv(real, sys.argv)


if __name__ == "__main__":
    main()
