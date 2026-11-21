// Client-side only, the server checks everything again. Rules come from the input attributes (required, type,
// minlength, data-match), messages from data-* attributes, and errors go in #<input id>-error
const forms = (() => {
    // Message of the first rule the input breaks, or ""
    const problemOf = (input) => {
        if (input.validity.valueMissing) return input.dataset.valueMissing ?? "";
        if (input.validity.typeMismatch) return input.dataset.typeMismatch ?? "";
        // Code points, like NIST counts password length. validity.tooShort only works on typed values
        if (input.minLength > 0 && [...input.value].length < input.minLength) return input.dataset.tooShort ?? "";
        const other = input.dataset.match ? input.form.elements.namedItem(input.dataset.match) : null;
        if (other !== null && other.value !== input.value) return input.dataset.mismatch ?? "";
        return "";
    };

    const check = (form) => {
        const inputs = [...form.elements].filter((element) => element instanceof HTMLInputElement && element.type !== "hidden");

        // The server sent the form back with errors, focus the first bad input
        const status = template.getStatus();
        if (status === "warn" || status === "error") {
            const target = inputs.find((input) => input.getAttribute("aria-invalid") === "true") ?? inputs.find((input) => input.value === "");
            if (target !== undefined) target.focus();
        }

        form.addEventListener("submit", (event) => {
            let firstInvalid = null;
            for (const input of inputs) {
                const error = document.getElementById(input.id + "-error");
                if (error === null) continue;
                const message = problemOf(input);
                error.textContent = message;
                input.setAttribute("aria-invalid", message === "" ? "false" : "true");
                if (message !== "" && firstInvalid === null) firstInvalid = input;
            }
            if (firstInvalid === null) return;
            event.preventDefault();
            const formMessage = form.querySelector(".form-message");
            if (formMessage !== null) formMessage.textContent = ""; // the server's message is stale now
            template.setStatus("error");
            firstInvalid.focus();
        });
    };

    return { check };
})();
