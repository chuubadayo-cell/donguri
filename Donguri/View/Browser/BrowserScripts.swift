//
//  BrowserScripts.swift
//  Donguri
//
//  What the browser injects into pages, and its ad blocker.
//
//  Scripts run in their own JavaScript world ("iroha"), so pages can't see
//  or break them: Hoshi Reader's selection.js for finding the tapped word,
//  plus a little glue for tap-to-look-up, closing the popup on scroll, and
//  following YouTube's on-screen subtitles.
//

import Foundation
import WebKit

enum BrowserScripts {
    static let world = WKContentWorld.world(name: "iroha")

    /// Tap-to-look-up and YouTube subtitle following. `selection.js` must
    /// be injected first.
    static let glue = """
    (function () {
      if (window.__iroha) { return; }
      window.__iroha = true;
      window.irohaLookup = false;

      // The looked-up word is marked the way Hoshi Reader and the thread
      // view mark it. selection.js sets a CSS highlight; the page needs the
      // rule that draws it.
      function ensureHighlightStyle() {
        if (document.getElementById('iroha-highlight-style')) { return; }
        const highlightStyle = document.createElement('style');
        highlightStyle.id = 'iroha-highlight-style';
        highlightStyle.textContent = '::highlight(hoshi-selection) { background-color: rgba(160, 160, 160, 0.45) !important; color: inherit; }';
        (document.head || document.documentElement).appendChild(highlightStyle);
      }
      ensureHighlightStyle();

      function highlight(sel, count) {
        ensureHighlightStyle();
        if (window.CSS && CSS.highlights) {
          sel.highlightSelection(count);
          return;
        }
        // No highlight API: fall back to a plain text selection.
        try {
          const first = sel.selection.ranges[0];
          const range = document.createRange();
          range.setStart(first.node, first.start);
          let remaining = count, node = first.node, end = first.start;
          for (const r of sel.selection.ranges) {
            const take = Math.min(remaining, r.end - r.start);
            node = r.node; end = r.start + take; remaining -= take;
            if (remaining <= 0) { break; }
          }
          range.setEnd(node, end);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } catch (e) {}
      }

      // Like hoshiSelection.selectText, but links and images don't stop it:
      // in lookup mode every tap is a lookup.
      function select(x, y, maxLength) {
        const sel = window.hoshiSelection;
        if (!sel) { return null; }
        const hit = sel.getCharacterAtPoint(x, y);
        if (!hit) { sel.clearSelection(); return null; }
        if (sel.selection && hit.node === sel.selection.startNode && hit.offset === sel.selection.startOffset) {
          sel.clearSelection();
          return null;
        }
        sel.clearSelection();
        const container = sel.findParagraph(hit.node) || document.body;
        const walker = sel.createWalker(container);
        let text = '';
        let node = hit.node;
        let offset = hit.offset;
        const ranges = [];
        walker.currentNode = node;
        while (text.length < maxLength && node) {
          const content = node.textContent;
          const start = offset;
          while (offset < content.length && text.length < maxLength) {
            const ch = content[offset];
            if (sel.isScanBoundary(ch)) { break; }
            text += ch;
            offset++;
          }
          if (offset > start) { ranges.push({ node: node, start: start, end: offset }); }
          if (offset < content.length || text.length >= maxLength) { break; }
          node = walker.nextNode();
          offset = 0;
        }
        if (!text) { return null; }
        const current = { startNode: hit.node, startOffset: hit.offset, ranges: ranges, text: text };
        sel.selection = current;
        const sentence = sel.getSentence(hit.node, hit.offset);
        // The app answers with how many characters the dictionary matched,
        // and the highlight goes on as soon as it does.
        const reply = webkit.messageHandlers.textSelected.postMessage({ text: text, sentence: sentence, rect: sel.getSelectionRect(x, y) });
        if (reply && reply.then) {
          reply.then(function (count) {
            if (count > 0 && sel.selection === current) { highlight(sel, count); }
          }).catch(function () {});
        }
        return text;
      }

      function editable(target) {
        const element = target && target.nodeType === 3 ? target.parentElement : target;
        return !!(element && element.closest && element.closest('input, textarea, select, [contenteditable="true"]'));
      }

      // Touches are answered on touchend, without waiting for the click
      // the browser sends some time later.
      let touch = null;
      let suppressClickUntil = 0;
      document.addEventListener('touchstart', function (e) {
        if (!window.irohaLookup || e.touches.length !== 1) { touch = null; return; }
        const t = e.touches[0];
        touch = { x: t.clientX, y: t.clientY, time: Date.now(), moved: false };
      }, { passive: true, capture: true });
      document.addEventListener('touchmove', function (e) {
        if (!touch) { return; }
        const t = e.touches[0];
        if (Math.abs(t.clientX - touch.x) > 10 || Math.abs(t.clientY - touch.y) > 10) { touch.moved = true; }
      }, { passive: true, capture: true });
      document.addEventListener('touchend', function (e) {
        const start = touch;
        touch = null;
        if (!start || start.moved || !window.irohaLookup || Date.now() - start.time > 600) { return; }
        if (editable(e.target)) { return; }
        const t = e.changedTouches[0];
        e.preventDefault();
        e.stopPropagation();
        suppressClickUntil = Date.now() + 800;
        if (!select(t.clientX, t.clientY, window.scanLength || 16)) {
          webkit.messageHandlers.tapOutside.postMessage(null);
        }
      }, { passive: false, capture: true });

      document.addEventListener('click', function (e) {
        if (!window.irohaLookup) { return; }
        if (editable(e.target)) { return; }
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        if (Date.now() < suppressClickUntil) { return; }
        if (!select(e.clientX, e.clientY, window.scanLength || 16)) {
          webkit.messageHandlers.tapOutside.postMessage(null);
        }
      }, true);

      let lastScroll = 0;
      window.addEventListener('scroll', function () {
        const now = Date.now();
        if (now - lastScroll > 400) {
          lastScroll = now;
          webkit.messageHandlers.scrolled.postMessage(null);
        }
      }, { passive: true });

      // YouTube: report each new on-screen subtitle line.
      let lastCaption = '';
      setInterval(function () {
        if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) { return; }
        const box = document.querySelector('.ytp-caption-window-container, .caption-window, .captions-text');
        let text = '';
        if (box) {
          const lines = box.querySelectorAll('.caption-visual-line');
          if (lines.length) {
            text = Array.from(lines).map(function (l) { return l.textContent; }).join('\\n');
          } else {
            const segments = box.querySelectorAll('.ytp-caption-segment');
            text = segments.length ? Array.from(segments).map(function (s) { return s.textContent; }).join('') : box.textContent;
          }
        }
        text = (text || '').trim();
        if (text && text !== lastCaption) {
          lastCaption = text;
          const video = document.querySelector('video');
          webkit.messageHandlers.caption.postMessage({ text: text, time: video ? video.currentTime : 0 });
        }
      }, 300);
    })();
    """

    /// Runs in the page's own world (it needs YouTube's player data): the
    /// whole subtitle track of the current video, Japanese preferred.
    static let fetchTranscript = """
    const player = document.querySelector('#movie_player');
    let response = null;
    try { response = player && player.getPlayerResponse ? player.getPlayerResponse() : null; } catch (e) {}
    if (!response) { response = window.ytInitialPlayerResponse || null; }
    if (!response && window.ytplayer && window.ytplayer.config && window.ytplayer.config.args) {
      try { response = JSON.parse(window.ytplayer.config.args.player_response || 'null'); } catch (e) {}
    }
    const tracks = (((response || {}).captions || {}).playerCaptionsTracklistRenderer || {}).captionTracks || [];
    if (!tracks.length) { return { error: 'none' }; }
    const japanese = tracks.filter(function (t) { return (t.languageCode || '').indexOf('ja') === 0; });
    const pick = japanese.find(function (t) { return t.kind !== 'asr'; }) || japanese[0] || tracks[0];
    const separator = pick.baseUrl.indexOf('?') >= 0 ? '&' : '?';
    const reply = await fetch(pick.baseUrl + separator + 'fmt=json3', { credentials: 'include' });
    const body = await reply.text();
    if (!body) { return { error: 'blocked' }; }
    const json = JSON.parse(body);
    const lines = [];
    for (const event of (json.events || [])) {
      if (!event.segs) { continue; }
      const text = event.segs.map(function (s) { return s.utf8 || ''; }).join('').replace(/\\n/g, ' ').trim();
      if (text) { lines.push({ time: (event.tStartMs || 0) / 1000, text: text }); }
    }
    return { language: pick.languageCode || '', automatic: pick.kind === 'asr', lines: lines };
    """

    // MARK: Ad blocking

    /// Ad and tracker hosts, general and Japanese. Blocked as third-party
    /// loads only, so the sites themselves still open.
    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "googletagmanager.com", "adservice.google.com", "adservice.google.co.jp",
        "amazon-adsystem.com", "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com",
        "quantserve.com", "moatads.com", "adsrvr.org", "casalemedia.com", "smartadserver.com",
        "yieldmo.com", "teads.tv", "sharethrough.com", "33across.com", "media.net", "zedo.com",
        "advertising.com", "adform.net", "bidswitch.net", "contextweb.com", "sonobi.com",
        // Japanese ad networks
        "i-mobile.co.jp", "microad.jp", "microad.net", "ad-stir.com", "nend.net", "zucks.net",
        "adingo.jp", "fluct.jp", "gmossp-sp.jp", "gmossp.jp", "logly.co.jp", "popin.cc",
        "socdm.com", "impact-ad.jp", "yads.yahoo.co.jp", "yads.c.yimg.jp", "ad.ad-stir.com",
        "adlantis.jp", "ad-generation.jp", "genieesspv.jp", "geniee.jp", "uncn.jp", "adpdx.com",
        "ad-m.asia", "bance.jp", "adjust-net.jp", "ladsp.com", "dsp.yahoo.co.jp", "i2i.jp",
        "trafficgate.net", "ads.yahoo.com", "adtdp.com", "fout.jp", "relaido.jp", "ad6media.fr",
        "imobile.co.jp", "ninja.co.jp", "shinobi.jp", "adroll.com", "ad.as.amanad.adtdp.com",
    ]

    /// Containers that pages leave empty when their ads are blocked. Plain
    /// class names only: substring selectors ([class*=…]) are checked
    /// against every element on every style change, which made big pages
    /// noticeably slower.
    private static let hiddenSelectors = [
        ".adsbygoogle", ".ad-banner", ".adBanner", ".ninja-recommend-block",
        ".OUTBRAIN", ".logly-lift", ".i-mobile-ad", ".microadCompass-ad",
    ]

    /// Big script-driven sites that don't need the element hiding.
    private static let unhiddenDomains = [
        "*youtube.com", "*google.com", "*google.co.jp", "*nicovideo.jp", "*pixiv.net",
        "*wikipedia.org", "*x.com", "*twitter.com",
    ]

    static var contentRules: String {
        var rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    // Like AdGuard's ||host^: the host or any subdomain of it.
                    "url-filter": "^[htpsw]+://([a-z0-9.-]+\\.)?\(escaped)[/:?]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*", "unless-domain": unhiddenDomains],
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")],
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
