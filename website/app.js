"use strict";

const calendar = document.querySelector("#calendar-preview");
const desktop = document.querySelector(".desktop-preview");
const themeButtons = document.querySelectorAll("[data-theme]");

for (const button of themeButtons) {
  button.addEventListener("click", () => {
    const theme = button.dataset.theme;
    calendar.src = `assets/calendar-${theme}.png`;
    calendar.alt = `CalDock ${theme === "dark" ? "深" : "浅"}色月历：公历、农历、节气和休班角标`;
    desktop.dataset.previewTheme = theme;
    for (const option of themeButtons) {
      option.setAttribute("aria-pressed", String(option === button));
    }
  });
}

document.querySelector("#year").textContent = String(new Date().getFullYear());

// Keep plain Release links usable when JavaScript, the API or the network is unavailable.
async function resolveDownloads() {
  try {
    const response = await fetch(
      "https://api.github.com/repos/yuhuotech/CalDock/releases/latest",
      {
        headers: { Accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!response.ok) return;
    const release = await response.json();
    if (
      release.draft ||
      release.prerelease ||
      !/^v\d+\.\d+\.\d+(?:\+[\w.-]+)?$/.test(release.tag_name)
    )
      return;
    const version = release.tag_name.slice(1).split("+")[0];
    const prefix = `https://github.com/yuhuotech/CalDock/releases/download/${encodeURIComponent(release.tag_name)}/`;
    for (const type of ["dmg", "zip"]) {
      const name = `CalDock-universal-${version}.${type}`;
      const asset = release.assets?.find(
        (item) => item.name === name && item.state === "uploaded",
      );
      if (!asset) continue;
      const url = new URL(asset.browser_download_url);
      if (url.href !== prefix + name) continue;
      for (const link of document.querySelectorAll(`[data-download="${type}"]`))
        link.href = url.href;
    }
    for (const label of document.querySelectorAll("[data-release-version]")) {
      label.textContent = `${release.tag_name} · Universal`;
    }
  } catch {
    // Static links remain available, including with an API rate limit or offline preview.
  }
}

resolveDownloads();
