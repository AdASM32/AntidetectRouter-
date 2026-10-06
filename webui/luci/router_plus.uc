// LuCI authenticates this route before handing its session to the panel API.
return {
    open_panel: function() {
        const sid = ctx.authsession;
        http.header('Cache-Control', 'no-store');

        for (let config in [ 'network', 'openvpn' ]) {
            if (!sid || ubus.call('session', 'access', {
                ubus_rpc_session: sid,
                scope: 'uci',
                object: config,
                function: 'write'
            })?.access != true) {
                http.status(403, 'Forbidden');
                http.prepare_content('text/plain; charset=UTF-8');
                http.write('Router Plus requires network and OpenVPN administration rights.');
                return;
            }
        }

        let page = http.formvalue('page') ?? 'dashboard';
        if (!match(page, /^(dashboard|pptp|openvpn|passwall|logs|network|advanced)$/))
            page = 'dashboard';

        const secure = http.getenv('HTTPS') == 'on' ? '; Secure' : '';
        http.header('Set-Cookie', `router_plus_session=${sid}; Path=/cgi-bin/vektort13; SameSite=Strict; HttpOnly${secure}`);
        http.redirect(`/vektort13-admin/#/${page}`);
    }
};
