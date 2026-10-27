//
//  XScripts.swift
//  Donguri
//
//  X (Twitter) for immersion: posts that aren't Japanese are hidden as
//  they appear, and so are posts with no text (only pictures or video),
//  posts X translated by itself, and ads. Searches are kept to Japanese
//  (lang:ja).
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
      // X's own bottom bar: the app's toolbar has its home and search.
      function addStyle() {
        if (document.getElementById('iroha-x-style')) { return; }
        const style = document.createElement('style');
        style.id = 'iroha-x-style';
        // The home timeline keeps only its first two tabs (おすすめ and
        // フォロー中), not pinned lists or communities; no compose button.
        style.textContent = [
          '[data-testid="BottomBar"]', '[data-testid="DMDrawer"]',
          // On home, X's own top bar (logo, avatar) and its feed tabs:
          // only おすすめ is shown, chosen by the script below.
          'html.iroha-home [data-testid="TopNavBar"]', 'html.iroha-home .iroha-x-header',
          'html.iroha-home [data-testid="primaryColumn"] [data-testid="ScrollSnap-List"] > div:nth-child(n+3)',
          'html.iroha-home [data-testid="primaryColumn"] [data-testid="ScrollSnap-nextButtonWrapper"]',
          'a[href="/compose/post"]', 'a[href="/compose/tweet"]',
          '[data-testid="FloatingActionButtonBase"]', '[data-testid="FloatingActionButtons_Tweet_Button"]',
          '[data-testid="SideNav_NewTweet_Button"]'
        ].join(',\n') + ' { display: none !important; }';
        (document.head || document.documentElement).appendChild(style);
      }
      addStyle();
      document.addEventListener('DOMContentLoaded', addStyle);
      // Japanese: some kana (which Chinese never has) and mostly Japanese
      // script. A post of only emoji, numbers or links isn't judged.
      function isJapanese(text) {
        const letters = (text || '').replace(/https?:\\/\\/\\S+|[@#][\\w_]+|[\\s\\d\\p{P}\\p{S}]/gu, '');
        if (!letters) { return true; }
        const japanese = (letters.match(/[\\u3040-\\u30ff\\u31f0-\\u31ff\\u3400-\\u9fff\\uff66-\\uff9f]/g) || []).length;
        const kana = (letters.match(/[\\u3040-\\u30ff\\u31f0-\\u31ff\\uff66-\\uff9f]/g) || []).length;
        return kana > 0 && japanese / letters.length >= 0.3;
      }
      // X's labels on a post it translated by itself ("Translated from …",
      // "原文を表示"). A translation reads as Japanese but isn't.
      const translated = /自動翻訳|から翻訳|翻訳されました|原文を表示|原文を見る|Translated from|Auto-?translated|Show original/i;
      function keep(article) {
        if (article.querySelector('[data-testid="placementTracking"]')) { return false; }
        const texts = article.querySelectorAll('[data-testid="tweetText"]');
        // Only pictures or a video: nothing to read.
        if (!texts.length) { return false; }
        // The labels around the post, not the post's own words.
        let around = article.textContent || '';
        texts.forEach(function (text) { around = around.replace(text.textContent || '', ''); });
        if (translated.test(around)) { return false; }
        const main = texts[0];
        return main.getAttribute('lang') === 'ja' || isJapanese(main.textContent);
      }
      // X's offers to translate a post or a bio into the UI's language.
      const translateLabel = /^(Translate post|Translate bio|Translate|Show translation|Rate this translation|ポストを翻訳|自己紹介を翻訳|翻訳を表示|翻訳する)$/i;
      function hideTranslateButtons(root) {
        // Each button is looked at once.
        root.querySelectorAll('button:not([data-iroha-t]), [role="button"]:not([data-iroha-t])').forEach(function (button) {
          const label = (button.textContent || '').trim();
          const hide = label.length <= 30 && translateLabel.test(label);
          button.dataset.irohaT = hide ? '1' : '0';
          if (hide) { button.style.display = 'none'; }
        });
      }
      // The home timeline's sticky header (X's top bar and the
      // おすすめ / フォロー中 tabs) is marked to be hidden, and おすすめ is
      // kept selected.
      let lastTabClick = 0;
      function homeHeader(column) {
        const tablist = column.querySelector('[role="tablist"]');
        if (!tablist) { return; }
        if (!column.querySelector('.iroha-x-header')) {
          let node = tablist;
          while (node && node !== column) {
            const position = getComputedStyle(node).position;
            if (position === 'sticky' || position === 'fixed') { break; }
            node = node.parentElement;
          }
          // No sticky container found: hide the tabs themselves.
          (node && node !== column ? node : tablist).classList.add('iroha-x-header');
        }
        const first = tablist.querySelector('[role="tab"]');
        if (first && first.getAttribute('aria-selected') !== 'true' && Date.now() - lastTabClick > 2000) {
          lastTabClick = Date.now();
          first.click();
        }
      }
      function cellOf(article) {
        return article.closest('[data-testid="cellInnerDiv"]') || article;
      }
      // Each post is judged once, again only if its text changes (X reuses
      // elements as the timeline scrolls). X's page changes constantly, and
      // judging every post on every change kept scrolling busy.
      const verdicts = new WeakMap();
      function judged(article) {
        const text = article.querySelector('[data-testid="tweetText"]');
        const signature = (text ? text.textContent.length + ':' + text.textContent.slice(0, 32) : '-') +
          '|' + (article.textContent || '').length;
        const known = verdicts.get(article);
        if (known && known.signature === signature) { return known.keep; }
        const verdict = keep(article);
        verdicts.set(article, { signature: signature, keep: verdict });
        return verdict;
      }
      function run() {
        addStyle();
        const home = location.pathname === '/home';
        if (document.documentElement.classList.contains('iroha-home') !== home) {
          document.documentElement.classList.toggle('iroha-home', home);
        }
        const column = document.querySelector('[data-testid="primaryColumn"]');
        if (column) { hideTranslateButtons(column); }
        if (home && column) { homeHeader(column); }
        const on = !!window.__irohaJapaneseOnly;
        // Filter off and nothing left hidden: nothing to do.
        if (!on && !document.querySelector('[data-iroha-hidden]')) { return; }
        // The post a page is about (opened by tapping it) always shows.
        const focused = location.pathname.indexOf('/status/') >= 0;
        document.querySelectorAll('article[data-testid="tweet"]').forEach(function (article, index) {
          const cell = cellOf(article);
          const hide = on && !(focused && index === 0) && !judged(article);
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
      }).observe(document.documentElement, { childList: true, subtree: true });

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
