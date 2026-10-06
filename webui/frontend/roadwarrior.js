/* Incoming device profile is independent of the chosen PPTP/proxy upstream. */
document.addEventListener('DOMContentLoaded', async () => {
    const notices = document.querySelectorAll('[data-roadwarrior-notice]');
    try {
        const response = await fetch('/cgi-bin/vektort13/roadwarrior-profile.sh?action=status');
        if (response.status === 403) {
            const page = window.location.hash.slice(2) || 'dashboard';
            window.location.replace(`/cgi-bin/luci/admin/router_plus?page=${encodeURIComponent(page)}`);
            return;
        }
        const data = await response.json();
        if (!response.ok || data.status !== 'ok') throw new Error(data.message || 'Не удалось проверить профиль OpenVPN');
        if (!data.available) {
            notices.forEach(element => { element.textContent = 'Входящий профиль ещё не создан. Сначала настройте OpenVPN-сервер роутера.'; });
            return;
        }
        document.querySelectorAll('[data-roadwarrior-download]').forEach(element => {
            element.href = '/cgi-bin/vektort13/roadwarrior-profile.sh?action=download';
            element.removeAttribute('aria-disabled');
            element.style.pointerEvents = '';
            element.style.opacity = '';
        });
        notices.forEach(element => { element.textContent = 'Импортируйте профиль в OpenVPN-клиент устройства. При смене PPTP или прокси повторно скачивать его не нужно.'; });
    } catch (error) {
        notices.forEach(element => { element.textContent = error.message; });
    }
});
