// Fetches the latest GitHub release and wires up the download UI.
// Falls back to the releases page if anything goes wrong.
(function () {
  "use strict";

  var REPO = "unfallenwill/minimax-code-linux";
  var API = "https://api.github.com/repos/" + REPO + "/releases/latest";
  var FALLBACK = "https://github.com/" + REPO + "/releases/latest";

  var state = { version: null, assets: [], date: null, distro: "deb" };

  function $(id) { return document.getElementById(id); }
  function setText(id, value) { var el = $(id); if (el) el.textContent = value; }

  function pickAsset(assets, distro) {
    // assets look like: minimax-code_3.0.43_amd64.deb / minimax-code-3.0.43.x86_64.rpm
    var ext = distro === "deb" ? ".deb" : ".rpm";
    var hints = ["x86_64", "amd64", "x64"];
    for (var i = 0; i < assets.length; i++) {
      var n = assets[i].name.toLowerCase();
      if (n.indexOf(ext) === -1) continue;
      for (var j = 0; j < hints.length; j++) {
        if (n.indexOf(hints[j]) !== -1) return assets[i];
      }
    }
    return null;
  }

  function pickChecksums(assets) {
    for (var i = 0; i < assets.length; i++) {
      var n = assets[i].name.toLowerCase();
      if (n.indexOf("checksums") === -1) continue;
      if (n.indexOf("amd64") !== -1) return assets[i];
    }
    return null;
  }

  function fmtDate(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }

  function fmtSize(bytes) {
    if (!bytes || bytes < 0) return "";
    var mb = bytes / 1048576;
    return (mb >= 100 ? Math.round(mb) : Math.round(mb * 10) / 10) + " MB";
  }

  function renderVersion() {
    if (state.version) {
      setText("version-value", state.version);
      setText("version-date", state.date ? "· " + fmtDate(state.date) : "");
      document.title = "MiniMax Code " + state.version + " · Linux 下载";
    } else {
      setText("version-value", "见 Releases");
      setText("version-date", "");
    }
  }

  function renderDownload() {
    var asset = pickAsset(state.assets, state.distro);
    var main = $("download-main");
    var label = $("download-label");
    var sub = $("download-sub");
    var cmd = $("install-cmd");
    var checksums = pickChecksums(state.assets);

    if (asset) {
      main.href = asset.browser_download_url;
      label.textContent = state.distro === "deb" ? "下载 .deb" : "下载 .rpm";
      var size = fmtSize(asset.size);
      sub.textContent = asset.name + (size ? " · " + size : "");
    } else {
      main.href = FALLBACK;
      label.textContent = "前往 Releases";
      sub.textContent = "暂未获取到安装包，请查看全部版本";
    }

    $("download-checksums").href = checksums ? checksums.browser_download_url : FALLBACK;

    if (asset) {
      var filename = "./" + asset.name;
      cmd.textContent = (state.distro === "deb" ? "sudo apt install " : "sudo dnf install ") + filename;
    } else {
      cmd.textContent = "# 暂时无法获取版本信息，请从 Releases 页面下载对应的安装包";
    }
  }

  function setTab(value) {
    var tabs = document.querySelectorAll("[data-distro]");
    for (var i = 0; i < tabs.length; i++) {
      var on = tabs[i].getAttribute("data-distro") === value;
      tabs[i].classList.toggle("active", on);
      tabs[i].setAttribute("aria-selected", on ? "true" : "false");
    }
  }

  function bindTabs() {
    var distroBtns = document.querySelectorAll("[data-distro]");
    for (var j = 0; j < distroBtns.length; j++) {
      distroBtns[j].addEventListener("click", function (e) {
        state.distro = e.currentTarget.getAttribute("data-distro");
        setTab(state.distro);
        renderDownload();
      });
    }
  }

  function bindCopy() {
    var btn = $("copy-cmd");
    btn.addEventListener("click", function () {
      var text = $("install-cmd").textContent;
      if (!text) return;
      var done = function () {
        btn.textContent = "已复制";
        btn.classList.add("copied");
        setTimeout(function () { btn.textContent = "复制"; btn.classList.remove("copied"); }, 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () {});
      } else {
        var ta = document.createElement("textarea");
        ta.value = text; document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); done(); } catch (e) {}
        document.body.removeChild(ta);
      }
    });
  }

  function init() {
    bindTabs();
    bindCopy();
    renderVersion();
    renderDownload();

    // GitHub can be slow or rate-limited; never leave the page on "加载中…".
    var controller = typeof AbortController !== "undefined" ? new AbortController() : null;
    var timer = controller ? setTimeout(function () { controller.abort(); }, 8000) : 0;

    fetch(API, {
      headers: { "Accept": "application/vnd.github+json" },
      signal: controller ? controller.signal : undefined,
    })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (rel) {
        // strip leading 'v' if present
        var tag = rel.tag_name || "";
        state.version = tag.replace(/^minimax-code-v/, "").replace(/^v/, "") || tag;
        state.assets = (rel.assets || []).filter(function (a) { return a && a.name; });
        state.date = rel.published_at || rel.created_at || null;
        renderVersion();
        renderDownload();
      })
      .catch(function (err) {
        // graceful fallback: links stay pointed at the releases page
        if (window.console) console.warn("release fetch failed:", err);
        state.version = null;
        state.assets = [];
        renderVersion();
        renderDownload();
      })
      .then(function () { if (timer) clearTimeout(timer); });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
