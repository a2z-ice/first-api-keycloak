$(document).ready(function () {
    // Highlight active nav link
    var path = window.location.pathname;
    $(".nav-links a").each(function () {
        if (path.startsWith($(this).attr("href")) && $(this).attr("href") !== "/") {
            $(this).css({ color: "white", background: "rgba(255,255,255,0.15)" });
        } else if (path === "/" && $(this).attr("href") === "/") {
            $(this).css({ color: "white", background: "rgba(255,255,255,0.15)" });
        }
    });
});
