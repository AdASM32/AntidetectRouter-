"""Integration checks against real OpenWrt CGI/UCI and the Linux routing stack.

The route fixture supplies a veth device instead of contacting a PPTP server.
PPP authentication, GRE transit and production deployment need a separate test.
"""
import http.client
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


IMAGE = os.environ.get("ROUTER_PLUS_TEST_IMAGE", "router-plus/openwrt-tests:24.10.2")
ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


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
            mkdir -p /usr/share/luci/menu.d /usr/share/ucode/luci/controller
            cp /src/webui/luci/router-plus.json /usr/share/luci/menu.d/
            cp /src/webui/luci/router_plus.uc /usr/share/ucode/luci/controller/
            chmod 644 /usr/share/luci/menu.d/router-plus.json /usr/share/ucode/luci/controller/router_plus.uc
            test_password="$(openssl rand -base64 24)"
            printf '%s\n%s\n' "$test_password" "$test_password" | passwd root >/dev/null 2>&1
            umask 077
            printf '%s' "$test_password" > /tmp/router-plus-test-password
            umask 022
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
            result = cls.shell(". /usr/share/libubox/jshn.sh; json_init; json_add_string username root; json_add_string password \"$(cat /tmp/router-plus-test-password)\"; json_add_int timeout 300; ubus call session login \"$(json_dump)\"", check=False)
            if result.returncode == 0:
                cls.session = json.loads(result.stdout)["ubus_rpc_session"]
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("rpcd did not register its session API")
        for _ in range(40):
            if cls.shell("ubus list service | grep -qx service", check=False).returncode == 0:
                break
            time.sleep(0.1)
        cls.shell("/etc/init.d/network start; /etc/init.d/dnsmasq start")

    def call(self, action="list", body=None, authenticated=True, method=None, origin=None, session=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {}
        if authenticated:
            headers["Cookie"] = f"sysauth={session or self.session}"
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
        readonly = json.loads(self.shell("ubus call session create '{\"timeout\":300}'").stdout)["ubus_rpc_session"]
        grant = json.dumps({"ubus_rpc_session": readonly, "scope": "uci", "objects": [["network", "read"], ["openvpn", "read"]]})
        self.docker("exec", self.container, "ubus", "call", "session", "grant", grant)
        self.assertEqual(self.call(session=readonly)[0], 403)
        self.docker("exec", self.container, "ubus", "call", "session", "set",
            json.dumps({"ubus_rpc_session": readonly,
                "values": {"username": "readonly", "token": secrets.token_hex(16)}}))
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        connection.request("GET", "/cgi-bin/luci/admin/router_plus", headers={"Cookie": f"sysauth_http={readonly}"})
        response = connection.getresponse()
        self.assertEqual(response.status, 403)
        self.assertIsNone(response.getheader("Set-Cookie"))
        self.assertIn(b"administration rights", response.read())
        connection.close()
        _, result = self.call("connect")
        self.assertEqual(result["status"], "error")
        _, result = self.call("save", {}, origin="https://untrusted.invalid")
        self.assertEqual(result["status"], "error")
        self.assertIn("origin", result["message"])

    def test_pptp_options_use_supported_mandatory_mppe(self):
        self.shell("cp -p /etc/ppp/options.pptp /tmp/router-plus-options-original; printf '%s\\n' 'lcp-echo-interval 9' >> /etc/ppp/options.pptp")
        self.addCleanup(lambda: self.shell("cp -p /tmp/router-plus-options-original /etc/ppp/options.pptp; rm -f /tmp/router-plus-options-original"))
        parse = "pppd dryrun plugin pptp.so pptp_server 192.0.2.10 file /etc/ppp/options.pptp"
        before = self.shell(parse, check=False)
        self.assertEqual(before.returncode, 2)
        self.assertIn("unrecognized option 'mppe'", before.stderr)
        self.shell("sh /src/webui/install/fix-pptp-options.sh")
        self.assertEqual(self.shell(parse).returncode, 0)
        options = self.shell("cat /etc/ppp/options.pptp").stdout.splitlines()
        for option in ["require-mppe-128", "nomppe-40", "nomppe-stateful", "lcp-echo-interval 9"]:
            self.assertIn(option, options)
        fixed = self.shell("sha256sum /etc/ppp/options.pptp").stdout
        self.shell("sh /src/webui/install/fix-pptp-options.sh")
        self.assertEqual(self.shell("sha256sum /etc/ppp/options.pptp").stdout, fixed)
        self.shell("cp -p /tmp/router-plus-options-original /etc/ppp/options.pptp; printf '%s\\n' 'router-plus-deliberately-invalid-option' >> /etc/ppp/options.pptp")
        custom = self.shell("sha256sum /etc/ppp/options.pptp").stdout
        self.assertNotEqual(self.shell("sh /src/webui/install/fix-pptp-options.sh", check=False).returncode, 0)
        self.assertEqual(self.shell("sha256sum /etc/ppp/options.pptp").stdout, custom)

    def test_browser_luci_login_hands_session_to_panel(self):
        # CookieJar enforces browser path rules; manually injecting Cookie would
        # hide the production bug caused by LuCI's /cgi-bin/luci/ cookie path.
        jar = http.cookiejar.CookieJar()
        browser = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(jar), NoRedirect())
        base = f"http://127.0.0.1:{self.port}"

        def request(path, data=None, content_type=None):
            headers = {"Content-Type": content_type} if content_type else {}
            req = urllib.request.Request(base + path, data=data, headers=headers)
            try:
                response = browser.open(req, timeout=15)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, response.headers, response.read()

        entry = "/cgi-bin/luci/admin/router_plus?page=pptp"
        status, headers, body = request(entry)
        self.assertEqual(status, 403)
        self.assertNotIn("Set-Cookie", headers)
        self.assertIn(b"luci_password", body)

        password = self.shell("cat /tmp/router-plus-test-password").stdout
        login = urllib.parse.urlencode({"luci_username": "root", "luci_password": password}).encode()
        status, headers, _ = request("/cgi-bin/luci/admin/status/overview", login,
            "application/x-www-form-urlencoded")
        self.assertEqual(status, 302)
        self.assertIn("path=/cgi-bin/luci/", headers.get("Set-Cookie", ""))
        api = "/cgi-bin/vektort13/pptp-control.sh?action=list"
        self.assertEqual(request(api)[0], 403)

        status, headers, _ = request(entry)
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "/vektort13-admin/#/pptp")
        cookie = headers.get("Set-Cookie", "")
        self.assertIn("router_plus_session=", cookie)
        self.assertIn("Path=/cgi-bin/vektort13", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(request(api)[0], 200)
        self.assertEqual(request("/cgi-bin/vektort13/roadwarrior-profile.sh?action=status")[0], 200)
        status, headers, _ = request("/cgi-bin/luci/admin/router_plus?page=https://untrusted.invalid")
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "/vektort13-admin/#/dashboard")

        profile = dict(name="Browser profile", server="192.0.2.10", username="fixture",
            password=secrets.token_hex(16), dns="1.1.1.1", mtu=1400, autostart=0)
        status, _, body = request("/cgi-bin/vektort13/pptp-control.sh?action=save",
            json.dumps(profile).encode(), "application/json")
        self.assertEqual(status, 200)
        result = json.loads(body)
        self.assertEqual(result["status"], "ok")
        self.addCleanup(lambda: self.call("delete", {"id": result["id"]}))

        # The dedicated panel cookie must not survive a LuCI logout as a usable
        # session, even if the browser still stores that cookie.
        self.assertEqual(request("/cgi-bin/luci/admin/logout")[0], 302)
        self.assertEqual(request(api)[0], 403)

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
