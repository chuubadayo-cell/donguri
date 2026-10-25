//
//  YouTubeAdScripts.swift
//  Donguri
//
//  YouTube serves its ads from youtube.com itself, so a content blocker
//  that blocks ad hosts never sees them. Two scripts do what ad blockers do
//  on YouTube instead:
//
//  - `prune` removes the ad schedule from the player's data before the
//    player reads it (uBlock Origin's json-prune approach): no ads load.
//  - `skip` handles any ad that gets through anyway: muted, run to its
//    end, and skipped as soon as it can be.
//

import WebKit

enum YouTubeAdScripts {
    /// Page world, at document start.
    static let prune = """
    (function () {
      if (window.__irohaAdPrune || !/(^|\\.)youtube\\.com$/.test(location.hostname)) { return; }
      window.__irohaAdPrune = true;
      const keys = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams', 'adSignalsInfo'];
      function prune(value, depth) {
        if (!value || typeof value !== 'object' || depth > 4) { return value; }
        for (const key of keys) { if (key in value) { try { delete value[key]; } catch (e) {} } }
        if (value.playerResponse) { prune(value.playerResponse, depth + 1); }
        if (Array.isArray(value)) { for (const item of value) { prune(item, depth + 1); } }
        if (value.response) { prune(value.response, depth + 1); }
        return value;
      }
      const parse = JSON.parse;
      JSON.parse = function () {
        const result = parse.apply(this, arguments);
        try { prune(result, 0); } catch (e) {}
        return result;
      };
      const json = Response.prototype.json;
      Response.prototype.json = function () {
        return json.apply(this, arguments).then(function (result) {
          try { prune(result, 0); } catch (e) {}
          return result;
        });
      };
      let initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: function () { return initial; },
          set: function (value) { initial = prune(value, 0); }
        });
      } catch (e) {}
    })();
    """

    /// Any world, at document start.
    static let skip = """
    (function () {
      if (window.__irohaAdSkip || !/(^|\\.)youtube\\.com$/.test(location.hostname)) { return; }
      window.__irohaAdSkip = true;
      let mutedForAd = false;
      setInterval(function () {
        const player = document.querySelector('#movie_player, .html5-video-player');
        const video = document.querySelector('video.html5-main-video') || document.querySelector('video');
        if (!player || !video) { return; }
        const ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
        if (ad) {
          if (!video.muted) { video.muted = true; mutedForAd = true; }
          if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
            video.currentTime = video.duration - 0.05;
          }
          const button = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button, .ytp-skip-ad button');
          if (button) { button.click(); }
        } else if (mutedForAd) {
          video.muted = false;
          mutedForAd = false;
        }
      }, 250);
    })();
    """

    /// Both scripts, for a web view showing YouTube.
    static func install(in controller: WKUserContentController, world: WKContentWorld) {
        controller.addUserScript(WKUserScript(source: prune, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: skip, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
    }
}
