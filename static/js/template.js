const template = (() => {
    const root = document.documentElement;
    const status = document.getElementById("status");
    const STATUSES = ["none", "ok", "warn", "error"];

    const getStatus = () => (status === null ? "none" : status.dataset.status);

    // Same values as the server's Status, anything else is a typo
    const setStatus = (value) => {
        if (!STATUSES.includes(value)) throw new TypeError(`template.setStatus: "${value}" is not one of ${STATUSES.join(", ")}`);
        if (status === null) return;
        status.dataset.status = value;
        status.textContent = value;
    };

    document.getElementById("theme-toggle")?.addEventListener("click", () => {
        const theme = root.dataset.theme === "light" ? "dark" : "light";
        root.dataset.theme = theme;
        try { localStorage.setItem("theme", theme); } catch (error) { /* storage is blocked */ }
    });

    return { getStatus, setStatus };
})();
