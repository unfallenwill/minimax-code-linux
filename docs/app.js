// Fetches the latest GitHub release and wires up the download UI.
// Falls back to the releases page if anything goes wrong.
(function () {
  "use strict";

  var REPO = "unfallenwill/minimax-code-linux";
  var API  = "https://api.github.com/repos/" + REPO + "/releases/latest";
  var FALLBACK = "https://github.com/" + REPO + "/releases/latest";

  var state = { version: null, assets: [], date: null, arch: "amd64", distro: "deb" };

  function $(id) { return document.getElementById(id); }

  function pickAsset(assets, arch, distro) {
    // assets look like: minimax-code_3.0.43_amd64.deb / minimax-code-3.0.43.x86_64.rpm
    var ext = distro === "deb" ? ".deb" : ".rpm";
    var hints = distro === "deb"
      ? ["amd64", "x86_64", "x64"]
      : ["x86_64", "amd64", "x64"];
    for (var i = 0; i < assets.length; i++) {
      var n = assets[i].name.toLowerCase();
      if (n.indexOf(ext) === -1) continue;
      for (var j = 0; j < hints.length; j++) {
        if (n.indexOf(hints[j]) !== -1) return assets[i];
      }
    }
    return null;
  }

  function pickChecksums(assets, arch) {
    for (var i = 0; i < assets.length; i++) {
      var n = assets[i].name.toLowerCase();
      if (n.indexOf("checksums") === -1) continue;
      if (n.indexOf(arch) !== -1 || n.indexOf("amd64") !== -1) return assets[i];
    }
    return null;
  }

  function fmtDate(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }

  function renderVersion() {
    if (state.version) {
      $("version-value").textContent = state.version;
      $("version-badge").textContent = "v" + state.version;
      $("version-date").textContent = state.date ? "· " + fmtDate(state.date) : "";
    } else {
      $("version-value").textContent = "见 Releases";
      $("version-badge").textContent = "v—";
    }
  }

  function renderDownload() {
    var asset = pickAsset(state.assets, state.arch, state.distro);
    var main = $("download-main");
    var label = $("download-label");
    var sub = $("download-sub");
    var cmd = $("install-cmd");
    var checksums = pickChecksums(state.assets, state.arch);

    if (asset) {
      main.href = asset.browser_download_url;
      main.classList.remove("disabled");
      label.textContent = state.distro === "deb" ? "下载 .deb" : "下载 .rpm";
      sub.textContent = asset.name;
    } else {
      main.href = FALLBACK;
      label.textContent = "前往 Releases";
      sub.textContent = "未找到匹配的安装包，请查看全部版本";
    }

    if (checksums) {
      $("download-checksums").href = checksums.browser_download_url;
    } else {
      $("download-checksums").href = FALLBACK;
    }

    var filename = asset ? "./" + asset.name : "minimax-code-package";
    if (state.distro === "deb") {
      cmd.textContent = "sudo apt install " + filename;
    } else {
      cmd.textContent = "sudo dnf install " + filename;
    }
  }

  function setTab(group, value) {
    var attr = group === "arch" ? "data-arch" : "data-distro";
    var tabs = document.querySelectorAll("[" + attr + "]");
    for (var i = 0; i < tabs.length; i++) {
      var on = tabs[i].getAttribute(attr) === value;
      tabs[i].classList.toggle("active", on);
      tabs[i].setAttribute("aria-selected", on ? "true" : "false");
    }
  }

  function bindTabs() {
    var archBtns = document.querySelectorAll("[data-arch]");
    var distroBtns = document.querySelectorAll("[data-distro]");
    for (var i = 0; i < archBtns.length; i++) {
      archBtns[i].addEventListener("click", function (e) {
        state.arch = e.currentTarget.getAttribute("data-arch");
        setTab("arch", state.arch);
        renderDownload();
      });
    }
    for (var j = 0; j < distroBtns.length; j++) {
      distroBtns[j].addEventListener("click", function (e) {
        state.distro = e.currentTarget.getAttribute("data-distro");
        setTab("distro", state.distro);
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

    fetch(API, { headers: { "Accept": "application/vnd.github+json" } })
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
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
