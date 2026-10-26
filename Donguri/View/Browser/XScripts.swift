//
//  XScripts.swift
//  Donguri
//
//  X (Twitter) for immersion: posts that aren't Japanese are hidden as
//  they appear, ads too, and searches are kept to Japanese (lang:ja).
//

import Foundation

enum XScripts {
    static let homeURL = URL(string: "https://x.com/home")!
    static let japaneseOnlyKey = "iroha.x.japaneseOnly"

    static var japaneseOnly: Bool {
        get { UserDefaults.standard.object(forKey: japaneseOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: japaneseOnlyKey) }
    }

    /// The filter, with the setting it starts with.
    static var source: String {
        "window.__irohaJapaneseOnly = \(japaneseOnly);\n" + filter
    }

    /// Turns the filter on or off on a page already showing.
    static func toggleScript(_ on: Bool) -> String {
        "window.__irohaJapaneseOnly = \(on); window.__irohaFilter && window.__irohaFilter();"
    }

    private static let filter = """
    (function () {
      if (window.__irohaFilter) { return; }
      // Japanese: some kana (which Chinese never has) and mostly Japanese
      // script. A post of only emoji, numbers or links isn't judged.
      function isJapanese(text) {
        const letters = (text || '').replace(/https?:\\/\\/\\S+|[@#][\\w_]+|[\\s\\d\\p{P}\\p{S}]/gu, '');
        if (!letters) { return true; }
        const japanese = (letters.match(/[\\u3040-\\u30ff\\u31f0-\\u31ff\\u3400-\\u9fff\\uff66-\\uff9f]/g) || []).length;
        const kana = (letters.match(/[\\u3040-\\u30ff\\u31f0-\\u31ff\\uff66-\\uff9f]/g) || []).length;
        return kana > 0 && japanese / letters.length >= 0.3;
      }
      function keep(article) {
        if (article.querySelector('[data-testid="placementTracking"]')) { return false; }
        const texts = article.querySelectorAll('[data-testid="tweetText"]');
        if (!texts.length) { return true; }
        const main = texts[0];
        return main.getAttribute('lang') === 'ja' || isJapanese(main.textContent);
      }
      function cellOf(article) {
        return article.closest('[data-testid="cellInnerDiv"]') || article;
      }
      function run() {
        const on = !!window.__irohaJapaneseOnly;
        // The post a page is about (opened by tapping it) always shows.
        const focused = location.pathname.indexOf('/status/') >= 0;
        document.querySelectorAll('article[data-testid="tweet"]').forEach(function (article, index) {
          const cell = cellOf(article);
          const hide = on && !(focused && index === 0) && !keep(article);
          if (hide) {
            if (cell.style.display !== 'none') { cell.style.display = 'none'; cell.dataset.irohaHidden = '1'; }
          } else if (cell.dataset.irohaHidden) {
            cell.style.display = ''; delete cell.dataset.irohaHidden;
          }
        });
      }
      window.__irohaFilter = run;
      let queued = false;
      new MutationObserver(function () {
        if (queued) { return; }
        queued = true;
        requestAnimationFrame(function () { queued = false; run(); });
      }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });

      // Searches only in Japanese.
      setInterval(function () {
        if (!window.__irohaJapaneseOnly || location.pathname !== '/search') { return; }
        const params = new URLSearchParams(location.search);
        const query = params.get('q') || '';
        if (query && !/(^|\\s)lang:/i.test(query)) {
          params.set('q', query + ' lang:ja');
          location.replace(location.pathname + '?' + params.toString());
        }
      }, 600);
    })();
    """
}
