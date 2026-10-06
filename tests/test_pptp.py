"""Integration checks against real OpenWrt CGI/UCI and the Linux routing stack.

The route fixture supplies a veth device instead of contacting a PPTP server.
PPP authentication, GRE transit and production deployment need a separate test.
"""
import http.client
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import unittest


IMAGE = os.environ.get("ROUTER_PLUS_TEST_IMAGE", "router-plus/openwrt-tests:24.10.2")
ROOT = Path(__file__).resolve().parents[1]


class PPTPIntegration(unittest.TestCase):
    @classmethod
    def docker(cls, *args, input=None, check=True):
        result = subprocess.run(
            ["docker", *args], input=input, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            env={**os.environ, "DOCKER_BUILDKIT": "0"},
        )
        if check and result.returncode:
            raise RuntimeError(f"Docker command failed ({result.returncode}): {result.stderr}")
        return result

    @classmethod
    def shell(cls, script, check=True):
        return cls.docker("exec", cls.container, "/bin/sh", "-c", script, check=check)

    @classmethod
    def setUpClass(cls):
        if cls.docker("image", "inspect", IMAGE, check=False).returncode:
            cls.docker("build", "--file", str(ROOT / "tests/Dockerfile.openwrt"), "--tag", IMAGE, str(ROOT))
        cls.container = f"router-plus-tests-{os.getpid()}-{secrets.token_hex(3)}"
        cls.addClassCleanup(lambda: cls.docker("rm", "-f", cls.container, check=False))
        init = """
            set -eu
            mkdir -p /var/run /var/lock /tmp/resolv.conf.d /usr/lib/router-plus /www/cgi-bin/vektort13
            cp /src/webui/cgi-bin/*.sh /www/cgi-bin/vektort13/
            mkdir -p /www/vektort13-admin
            cp /src/webui/frontend/* /www/vektort13-admin/
            chmod -R a+rX /www/vektort13-admin
            chmod 755 /www/cgi-bin/vektort13/*.sh
            ln -s /src/rwpatch/scripts/pptp-runtime.sh /usr/lib/router-plus/pptp-runtime.sh
            touch /etc/config/network /etc/config/openvpn
            uci set network.loopback=interface
            uci set network.loopback.device=lo
            uci set network.loopback.proto=static
            uci set network.loopback.ipaddr=127.0.0.1
            uci set network.loopback.netmask=255.0.0.0
            uci set openvpn.rw=openvpn
            uci set openvpn.rw.dev=tun
            uci set openvpn.rw.enabled=1
            uci commit network
            uci commit openvpn
            /sbin/ubusd &
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                ubus list >/dev/null 2>&1 && break
                sleep 1
            done
            ubus list >/dev/null
            /sbin/rpcd &
            /sbin/procd -S >/tmp/procd-test.log 2>&1 &
            exec /usr/sbin/uhttpd -f -p 0.0.0.0:8080 -h /www -i .sh=/bin/sh
        """
        cls.docker("run", "-d", "--name", cls.container, "--cap-add", "NET_ADMIN",
                   "--publish", "127.0.0.1::8080", "--mount",
                   f"type=bind,src={ROOT},dst=/src,readonly", IMAGE, "/bin/sh", "-c", init)
        cls.port = int(cls.docker("port", cls.container, "8080/tcp").stdout.strip().rsplit(":", 1)[1])
        for _ in range(40):
            result = cls.shell("ubus call session create '{\"timeout\":300}'", check=False)
            if result.returncode == 0:
                cls.session = json.loads(result.stdout)["ubus_rpc_session"]
                grant = json.dumps({"ubus_rpc_session": cls.session, "scope": "luci", "objects": [["*", "*"]]})
                cls.docker("exec", cls.container, "ubus", "call", "session", "grant", grant)
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("rpcd did not register its session API")
        for _ in range(40):
            if cls.shell("ubus list service | grep -qx service", check=False).returncode == 0:
                break
            time.sleep(0.1)
        cls.shell("/etc/init.d/network start; /etc/init.d/dnsmasq start")

    def call(self, action="list", body=None, authenticated=True, method=None, origin=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {}
        if authenticated:
            headers["Cookie"] = f"sysauth={self.session}"
        if body is not None:
            headers["Content-Type"] = "application/json"
        if origin is not None:
            headers["Origin"] = origin
        connection.request(method or ("POST" if body is not None else "GET"),
                           f"/cgi-bin/vektort13/pptp-control.sh?action={action}",
                           json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        status, data = response.status, json.loads(response.read())
        connection.close()
        return status, data

    def create(self, **changes):
        body = dict(name='Test "PPTP"', server="192.0.2.10", username="test-user",
                    password=secrets.token_hex(16), dns="1.1.1.1 8.8.8.8", mtu=1400, autostart=0)
        body.update(changes)
        status, result = self.call("save", body)
        self.assertEqual(status, 200)
        self.assertEqual(result["status"], "ok", result)
        profile = result["id"]
        self.addCleanup(lambda: self.call("delete", {"id": profile}))
        return profile, body

    def test_authentication_and_request_contract(self):
        status, result = self.call(authenticated=False)
        self.assertEqual(status, 403)
        self.assertIn("Authentication", result["message"])
        _, result = self.call("connect")
        self.assertEqual(result["status"], "error")
        _, result = self.call("save", {}, origin="https://untrusted.invalid")
        self.assertEqual(result["status"], "error")
        self.assertIn("origin", result["message"])

    def test_incoming_openvpn_profile_download_requires_authentication(self):
        self.addCleanup(lambda: self.shell("rm -f /root/router-plus-fixture.ovpn /tmp/profile-test.ovpn /tmp/profile-test-ca.pem /tmp/profile-test-key.pem; uci -q delete openvpn.rw.ca; uci commit openvpn", check=False))
        self.shell("""
            set -eu
            openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/profile-test-key.pem -out /tmp/profile-test-ca.pem -subj /CN=profile-fixture -days 1 >/dev/null 2>&1
            uci set openvpn.rw.ca=/tmp/profile-test-ca.pem
            uci commit openvpn
            { printf '%s\n' client 'dev tun' 'remote 192.0.2.40 1194' '<ca>'; cat /tmp/profile-test-ca.pem; printf '%s\n' '</ca>' '<cert>'; cat /tmp/profile-test-ca.pem; printf '%s\n' '</cert>' '<key>'; cat /tmp/profile-test-key.pem; printf '%s\n' '</key>'; } > /root/router-plus-fixture.ovpn
        """)
        def request(action, auth=True):
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
            connection.request("GET", f"/cgi-bin/vektort13/roadwarrior-profile.sh?action={action}", headers={"Cookie": f"sysauth={self.session}"} if auth else {})
            response = connection.getresponse()
            result = response.status, dict(response.getheaders()), response.read()
            connection.close()
            return result
        for action in ["status", "download"]:
            self.assertEqual(request(action, auth=False)[0], 403)
        status, _, body = request("status")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["filename"], "router-plus-fixture.ovpn")
        status, headers, body = request("download")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn('attachment;', headers["Content-Disposition"])
        import hashlib
        expected = self.shell("sha256sum /root/router-plus-fixture.ovpn").stdout.split()[0]
        self.assertEqual(hashlib.sha256(body).hexdigest(), expected)
        self.shell("mv /root/router-plus-fixture.ovpn /tmp/profile-test.ovpn; ln -s /tmp/profile-test.ovpn /root/router-plus-fixture.ovpn")
        self.assertFalse(json.loads(request("status")[2])["available"])
        self.assertEqual(request("download")[0], 404)

    def test_profile_roundtrip_and_password_preservation(self):
        profile, body = self.create()
        _, result = self.call()
        entry = next(item for item in result["profiles"] if item["id"] == profile)
        self.assertEqual(entry["name"], body["name"])
        self.assertEqual(entry["server"], body["server"])
        self.assertTrue(entry["password_set"])
        self.assertNotIn("password", entry)
        self.assertNotIn(body["password"], json.dumps(result))
        body.update(id=profile, name="Renamed", password="")
        _, result = self.call("save", body)
        self.assertEqual(result["status"], "ok", result)
        saved = self.docker("exec", self.container, "uci", "-q", "get", f"network.{profile}.password").stdout.strip()
        self.assertTrue(saved)
        self.assertEqual(self.shell("uci -q get openvpn.rw.enabled").stdout.strip(), "1")
        self.assertEqual(self.shell(f"uci -q get network.{profile}.defaultroute").stdout.strip(), "0")
        _, result = self.call("delete", {"id": profile})
        self.assertEqual(result["status"], "ok", result)
        self.assertNotIn(profile, [item["id"] for item in self.call()[1]["profiles"]])

    def test_invalid_inputs_and_literal_credentials(self):
        for changes in [dict(server="bad;touch /tmp/injected"), dict(server="999.2.3.4"),
                        dict(username="bad\nuser"), dict(username=[]), dict(dns="8.8.8.999"), dict(mtu=1600)]:
            body = dict(name="invalid", server="192.0.2.10", username="test", password="test",
                        dns="", mtu=1400, autostart=0)
            body.update(changes)
            self.assertEqual(self.call("save", body)[1]["status"], "error")
        profile, body = self.create(password="$(touch /tmp/pptp-injected); 'quoted' \\ text")
        saved = self.docker("exec", self.container, "uci", "-q", "get", f"network.{profile}.password").stdout.rstrip("\n")
        self.assertEqual(saved, body["password"])
        self.assertEqual(self.shell("test ! -e /tmp/pptp-injected").returncode, 0)

    def test_unavailable_connection_does_not_stop_openvpn(self):
        profile, _ = self.create()
        _, result = self.call("connect", {"id": profile})
        self.assertEqual(result["status"], "error")
        self.assertEqual(self.shell("uci -q get openvpn.rw.enabled").stdout.strip(), "1")
        self.assertFalse(self.call()[1]["selected"])

    def test_direct_openvpn_client_stops_without_touching_server(self):
        self.addCleanup(lambda: self.shell("kill $(cat /var/run/openvpn-directtest.pid 2>/dev/null) 2>/dev/null; uci -q delete openvpn.directtest; uci commit openvpn; rm -f /var/run/openvpn-directtest.pid /tmp/directtest.ovpn /tmp/directtest-ca.pem /tmp/directtest-key.pem", check=False))
        self.shell("""
            set -eu
            openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/directtest-key.pem -out /tmp/directtest-ca.pem -subj /CN=fixture -days 1 >/dev/null 2>&1
            printf '%s\n' client 'dev null' 'remote 192.0.2.10 1194' 'ca /tmp/directtest-ca.pem' 'cert /tmp/directtest-ca.pem' 'key /tmp/directtest-key.pem' > /tmp/directtest.ovpn
            uci set openvpn.directtest=openvpn
            uci set openvpn.directtest.config=/tmp/directtest.ovpn
            uci commit openvpn
            openvpn --config /tmp/directtest.ovpn --daemon --writepid /var/run/openvpn-directtest.pid --log /tmp/directtest.log
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                test -s /var/run/openvpn-directtest.pid && break
                sleep 1
            done
            test -s /var/run/openvpn-directtest.pid
        """)
        pid = self.shell("cat /var/run/openvpn-directtest.pid").stdout.strip()
        self.assertEqual(self.shell(f"kill -0 {pid}").returncode, 0)
        self.shell(". /usr/lib/router-plus/pptp-runtime.sh; pptp_stop_openvpn_client rw; pptp_stop_openvpn_client directtest")
        self.assertEqual(self.shell("uci -q get openvpn.rw.enabled").stdout.strip(), "1")
        self.assertNotEqual(self.shell(f"kill -0 {pid}", check=False).returncode, 0)

    def test_dns_restore_preserves_subsequent_user_changes(self):
        profile, _ = self.create()
        self.shell(f"""
            set -eu
            rm -f /tmp/router-plus/dns-before /tmp/router-plus/dns-owned /tmp/router-plus/noresolv-before
            uci -q delete 'dhcp.@dnsmasq[0].server' || :
            uci add_list 'dhcp.@dnsmasq[0].server=9.9.9.9'
            uci set 'dhcp.@dnsmasq[0].noresolv=0'
            uci commit dhcp
            . /usr/lib/router-plus/pptp-runtime.sh
            pptp_dns_apply {profile} lo
        """)
        self.assertIn("1.1.1.1@lo", self.shell("uci -q get 'dhcp.@dnsmasq[0].server'").stdout)
        self.shell(". /usr/lib/router-plus/pptp-runtime.sh; pptp_dns_restore")
        self.assertEqual(self.shell("uci -q get 'dhcp.@dnsmasq[0].server'").stdout.strip(), "9.9.9.9")
        self.assertEqual(self.shell("uci -q get 'dhcp.@dnsmasq[0].noresolv'").stdout.strip(), "0")
        self.shell(f". /usr/lib/router-plus/pptp-runtime.sh; pptp_dns_apply {profile} lo; uci -q delete 'dhcp.@dnsmasq[0].server'; uci add_list 'dhcp.@dnsmasq[0].server=4.2.2.2'; uci commit dhcp; pptp_dns_restore")
        self.assertEqual(self.shell("uci -q get 'dhcp.@dnsmasq[0].server'").stdout.strip(), "4.2.2.2")

    def test_hostname_keeps_resolved_address_for_reconnection(self):
        profile, _ = self.create(server="localhost")
        self.shell(f". /usr/lib/router-plus/pptp-runtime.sh; pptp_pin_server {profile}")
        self.assertEqual(self.shell(f"uci -q get network.{profile}.server").stdout.strip(), "127.0.0.1")
        self.assertEqual(next(item for item in self.call()[1]['profiles'] if item['id'] == profile)['server'], "localhost")
        self.shell(f". /usr/lib/router-plus/pptp-runtime.sh; resolveip() {{ return 1; }}; pptp_pin_server {profile}")
        self.assertEqual(self.shell(f"uci -q get network.{profile}.server").stdout.strip(), "127.0.0.1")

    def test_kernel_routing_guard_and_link_loss(self):
        profile, _ = self.create()
        setup = f"""
            set -eu
            ip link add tun0 type veth
            ip addr add 10.99.0.1/24 dev tun0
            ip link set tun0 up
            ip link add pptp-test type veth
            ip addr add 198.18.0.1/30 dev pptp-test
            ip link set pptp-test up
            for peer in $(ip -o link show | awk -F': ' '$2 ~ /^veth/ {{ sub(/@.*/, "", $2); print $2 }}'); do
                ip link set "$peer" up
            done
            mkdir -p /tmp/router-plus
            printf '%s' '{profile}' >/tmp/router-plus/pptp-selected
            uci -q delete 'dhcp.@dnsmasq[0].server' || :
            uci add_list 'dhcp.@dnsmasq[0].server=1.1.1.1@pptp-test'
            uci add_list 'dhcp.@dnsmasq[0].server=8.8.8.8@pptp-test'
            uci set 'dhcp.@dnsmasq[0].noresolv=1'
            uci commit dhcp
            . /usr/lib/router-plus/pptp-runtime.sh
            pptp_device() {{ echo pptp-test; }}
            pptp_reconcile
        """
        self.addCleanup(lambda: self.shell("rm -f /tmp/router-plus/pptp-selected; ip link del tun0; ip link del pptp-test; nft delete table inet router_plus_pptp; ip rule del pref 104; ip rule del pref 105; ip route flush table 201", check=False))
        self.shell(setup)
        route = self.shell("ip -4 route get 203.0.113.1 from 10.99.0.2 iif tun0").stdout
        self.assertIn("dev pptp-test", route)
        guard = self.shell("nft list table inet router_plus_pptp").stdout
        self.assertIn('meta nfproto ipv6 drop', guard)
        self.assertIn('oifname != "pptp-test" drop', guard)
        self.assertIn('th dport 53 drop', guard)
        self.shell("ip link del pptp-test; . /usr/lib/router-plus/pptp-runtime.sh; pptp_reconcile")
        failure = self.shell("ip -4 route get 203.0.113.1 from 10.99.0.2 iif tun0", check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn('iifname "tun0" drop', self.shell("nft list table inet router_plus_pptp").stdout)

    def test_z_native_installer_retains_existing_configuration(self):
        self.shell("uci set firewall.vpn=zone; uci set firewall.vpn.name=vpn; uci set firewall.vpn.input=ACCEPT; uci commit firewall; /etc/init.d/firewall start; /etc/init.d/uhttpd start")
        self.shell("sh /src/webui/install/install-plus.sh")
        self.assertEqual(self.shell("uci -q get openvpn.rw.enabled").stdout.strip(), "1")
        self.assertEqual(self.shell("uci -q get router_plus.main.installed").stdout.strip(), "1")
        self.assertEqual(self.shell("test -x /etc/init.d/pptp-plus; test -x /www/cgi-bin/vektort13/pptp-control.sh; test -f /www/vektort13-admin/pptp.js").returncode, 0)


if __name__ == "__main__":
    unittest.main()
