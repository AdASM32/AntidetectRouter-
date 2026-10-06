/* PPTP extension: existing OpenVPN/Passwall navigation and controls stay intact. */
(() => {
    'use strict';
    const api = '/cgi-bin/vektort13/pptp-control.sh';
    const byId = id => document.getElementById(id);
    let busy = false;
    let loading = false;

    function message(text, error = false) {
        const target = byId('pptp-message');
        target.textContent = text;
        target.style.color = error ? '#f87171' : '';
    }

    async function request(action, body) {
        const options = body ? {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        } : {};
        const response = await fetch(`${api}?action=${action}`, options);
        const data = await response.json();
        if (!response.ok || data.status !== 'ok') {
            throw new Error(data.message || 'Не удалось выполнить запрос');
        }
        return data;
    }

    function resetForm() {
        byId('pptp-form').reset();
        byId('pptp-id').value = '';
        byId('pptp-form-title').textContent = 'Добавить подключение';
    }

    function edit(profile) {
        for (const key of ['id', 'name', 'server', 'username', 'dns', 'mtu']) {
            byId(`pptp-${key}`).value = profile[key] ?? '';
        }
        byId('pptp-password').value = '';
        byId('pptp-autostart').checked = profile.autostart;
        byId('pptp-form-title').textContent = 'Редактировать подключение';
        byId('pptp-name').focus();
    }

    async function mutate(action, body) {
        if (busy) return;
        busy = true;
        byId('page-pptp').querySelectorAll('button').forEach(button => { button.disabled = true; });
        try {
            const data = await request(action, body);
            message(data.message || 'Готово');
            if (action === 'save') resetForm();
            await load();
        } catch (error) {
            message(error.message, true);
        } finally {
            busy = false;
            byId('page-pptp').querySelectorAll('button').forEach(button => {
                button.disabled = button.dataset.disabledByPolicy === '1';
            });
        }
    }

    function button(text, callback, disabled = false) {
        const element = document.createElement('button');
        element.type = 'button';
        element.className = 'btn';
        element.textContent = text;
        element.dataset.disabledByPolicy = disabled ? '1' : '0';
        element.disabled = disabled || busy;
        element.addEventListener('click', callback);
        return element;
    }

    async function load() {
        if (loading) return;
        loading = true;
        try {
            const data = await request('list');
            const target = byId('pptp-profiles');
            target.replaceChildren();
            if (!data.available) {
                const notice = document.createElement('p');
                notice.textContent = 'Для подключения запустите установщик PPTP-расширения на роутере. Профили можно подготовить заранее.';
                target.append(notice);
            }
            if (!data.profiles.length) {
                const empty = document.createElement('p');
                empty.textContent = 'Подключений пока нет.';
                target.append(empty);
            }
            const states = { stopped: 'Отключён', connecting: 'Подключается', connected: 'Подключён', disconnected: 'Соединение прервано, трафик заблокирован' };
            for (const profile of data.profiles) {
                const row = document.createElement('div');
                row.className = 'section';
                const heading = document.createElement('h3');
                heading.textContent = profile.name;
                const details = document.createElement('p');
                details.textContent = `${profile.server} — ${states[profile.state] || profile.state}${data.selected === profile.id ? ' (выбран)' : ''}${profile.device ? ` · ${profile.device}` : ''}${profile.error ? ` · ${profile.error}` : ''}`;
                row.append(heading, details);
                row.append(
                    button('Подключить', () => mutate('connect', { id: profile.id }), !data.available),
                    button('Отключить', () => mutate('disconnect', { id: profile.id }), profile.state === 'stopped'),
                    button('Редактировать', () => edit(profile)),
                    button('Удалить', () => {
                        if (confirm(`Удалить PPTP-профиль «${profile.name}»?`)) mutate('delete', { id: profile.id });
                    })
                );
                target.append(row);
            }
        } catch (error) {
            message(error.message, true);
        } finally {
            loading = false;
        }
    }

    document.addEventListener('DOMContentLoaded', () => {
        byId('pptp-form').addEventListener('submit', event => {
            event.preventDefault();
            const body = {};
            for (const key of ['id', 'name', 'server', 'username', 'password', 'dns', 'mtu']) {
                body[key] = byId(`pptp-${key}`).value;
            }
            body.autostart = byId('pptp-autostart').checked ? 1 : 0;
            mutate('save', body);
        });
        byId('pptp-cancel').addEventListener('click', resetForm);
        const refresh = () => {
            if (byId('page-pptp').classList.contains('active') && !busy) load();
        };
        window.addEventListener('hashchange', refresh);
        setInterval(refresh, 5000);
        refresh();
    });
})();
