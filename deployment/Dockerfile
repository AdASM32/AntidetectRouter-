FROM openwrt/rootfs@sha256:3c8adad624f661f683e9e5d2977bc44fa4b29a17f76eb5c45d0aec8e079668cc
RUN mkdir -p /var/run /var/lock /tmp/resolv.conf.d \
    && opkg update \
    && opkg install ppp-mod-pptp ip-full curl openvpn-openssl openssl-util jq luci-app-openvpn
COPY . /opt/router-plus/
RUN mkdir -p /www/vektort13-admin /www/cgi-bin/vektort13 /usr/lib/router-plus \
    && cp /opt/router-plus/webui/frontend/* /www/vektort13-admin/ \
    && cp /opt/router-plus/webui/cgi-bin/*.sh /www/cgi-bin/vektort13/ \
    && cp /opt/router-plus/rwpatch/scripts/pptp-*.sh /usr/lib/router-plus/ \
    && mkdir -p /usr/share/luci/menu.d /usr/share/ucode/luci/controller \
    && cp /opt/router-plus/webui/luci/router-plus.json /usr/share/luci/menu.d/ \
    && cp /opt/router-plus/webui/luci/router_plus.uc /usr/share/ucode/luci/controller/ \
    && chmod 644 /usr/share/luci/menu.d/router-plus.json /usr/share/ucode/luci/controller/router_plus.uc \
    && chmod -R a+rX /www/vektort13-admin \
    && chmod 755 /www/cgi-bin/vektort13/*.sh /usr/lib/router-plus/*.sh
CMD ["/bin/sh", "/opt/router-plus/deployment/openwrt-entrypoint.sh"]
