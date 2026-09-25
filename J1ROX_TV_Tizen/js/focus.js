(function (app) {
    'use strict';
    function available(root) {
        return Array.prototype.filter.call((root || document).querySelectorAll('[data-focus]'), function (el) {
            return !el.disabled && el.getClientRects().length && el.offsetWidth > 0;
        });
    }
    function set(el) {
        if (!el) return;
        el.focus();
        // Native nearest scrolling keeps the horizontal rail and vertical page in view.
        try { el.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }
        catch (err) { el.scrollIntoView(false); }
    }
    app.focus = {
        set: set, available: available,
        restore: function (id, root) {
            var options = available(root);
            set(options.filter(function (el) { return el.getAttribute('data-focus') === id; })[0] || options[0]);
        },
        move: function (direction, root) {
            var options = available(root), active = document.activeElement;
            if (options.indexOf(active) < 0) { set(options[0]); return; }
            var rect = active.getBoundingClientRect(), best = null, score = Infinity;
            var x = (rect.left + rect.right) / 2, y = (rect.top + rect.bottom) / 2;
            options.forEach(function (el) {
                if (el === active) return;
                var r = el.getBoundingClientRect(), dx = (r.left + r.right) / 2 - x, dy = (r.top + r.bottom) / 2 - y;
                var horizontal = direction === 37 || direction === 39;
                var primary = horizontal ? dx * (direction === 37 ? -1 : 1) : dy * (direction === 38 ? -1 : 1);
                if (primary <= 1) return;
                var overlap = horizontal ? r.bottom > rect.top && r.top < rect.bottom : r.right > rect.left && r.left < rect.right;
                var candidate = primary + Math.abs(horizontal ? dy : dx) * 2 + (overlap ? 0 : 10000);
                if (candidate < score) { best = el; score = candidate; }
            });
            set(best || active);
        }
    };
}(window.JTV));
