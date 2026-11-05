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
    /// The signed-in account's @handle, once seen.
    static let handleKey = "iroha.x.handle"

    static var japaneseOnly: Bool {
        get { UserDefaults.standard.object(forKey: japaneseOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: japaneseOnlyKey) }
    }

    /// Finds the signed-in account's handle (a callAsyncJavaScript body,
    /// run in the page's world). X's phone layout has no profile link and
    /// its embedded state doesn't reliably name the account, so: any
    /// profile link, the avatar in its hidden top bar (whose test id ends
    /// in the handle), then the account settings X's site itself requests.
    static let handleScript = """
    const link = document.querySelector('a[data-testid="AppTabBar_Profile_Link"]');
    if (link) { return link.getAttribute('href').slice(1); }
    const avatar = document.querySelector('[data-testid="DashButton_ProfileIcon_Link"] [data-testid^="UserAvatar-Container-"], [data-testid="TopNavBar"] [data-testid^="UserAvatar-Container-"]');
    if (avatar) {
      const name = avatar.getAttribute('data-testid').slice('UserAvatar-Container-'.length);
      if (name && name !== 'unknown') { return name; }
    }
    const csrf = document.cookie.match(/(?:^|; )ct0=([^;]+)/);
    if (!csrf) { return null; }
    try {
      const response = await fetch('/i/api/1.1/account/settings.json', {
        credentials: 'include',
        headers: {
          'authorization': 'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA',
          'x-csrf-token': csrf[1],
          'x-twitter-auth-type': 'OAuth2Session',
          'x-twitter-active-user': 'yes'
        }
      });
      if (!response.ok) { return null; }
      return (await response.json()).screen_name || null;
    } catch (e) { return null; }
    """

    /// The filter, with the setting it starts with.
    static var source: String {
        "window.__irohaJapaneseOnly = \(japaneseOnly);\n" + filter
    }

    /// Turns the filter on or off on a page already showing.
    /// Where copied post links point: a site that shows X posts as proper
    /// embeds where they're pasted.
    static let shareHostKey = "iroha.x.shareHost"
    static let shareHosts = ["girlcockx.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "x.com"]

    static var shareHost: String {
        get { UserDefaults.standard.string(forKey: shareHostKey) ?? "girlcockx.com" }
        set { UserDefaults.standard.set(newValue, forKey: shareHostKey) }
    }

    /// "/user/status/123" as a link on the chosen site.
    static func shareLink(for path: String) -> URL? {
        guard path.range(of: #"^/[A-Za-z0-9_]+/status/\d+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + shareHost + path)
    }

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
        // X reduced to reading: no top or bottom bar (the app's toolbar
        // has home, search and back), no composing, no Grok, and on each
        // post no ⋯ menu, repost or share.
        style.textContent = [
          '[data-testid="BottomBar"]', '[data-testid="DMDrawer"]', '[data-testid="TopNavBar"]',
          'header[role="banner"]', '.iroha-x-header',
          'a[href="/compose/post"]', 'a[href="/compose/tweet"]',
          '[data-testid="FloatingActionButtonBase"]', '[data-testid="FloatingActionButtons_Tweet_Button"]',
          '[data-testid="SideNav_NewTweet_Button"]', '[data-testid="tweetButtonInline"]',
          '.iroha-x-composer',
          'a[href^="/i/grok"]', '[data-testid="GrokDrawer"]', '[data-testid="grokImgGen"]',
          '[data-testid="caret"]', '[data-testid="retweet"]', '[data-testid="unretweet"]',
          '[data-testid="icon-verified"]', 'svg[aria-label="認証済みアカウント"]', 'svg[aria-label="Verified account"]',
          '.iroha-x-gone'
        ].join(',\\n') + ' { display: none !important; }';
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
      // The label can sit inside the post's text block, so the whole post
      // is searched. Translations from Korean and Chinese are kept.
      const translated = /自動翻訳|から翻訳|翻訳されました|翻訳済み|原文を表示|原文を見る|Translated from|Translated by|Auto-?translated|Show original|See original/i;
      const keptOrigin = /韓国語|朝鮮語|ハングル|中国語|繁体字|簡体字|広東語|Korean|Chinese|Cantonese|Mandarin/i;
      // X's language for the original text, where it isn't Japanese and
      // the text shown is: a translation. (und, qme… are X's "unknown",
      // "media only" and the like.)
      const neutralLangs = { ja: 1, ko: 1, zh: 1, 'zh-cn': 1, 'zh-tw': 1, und: 1, zxx: 1, art: 1, qme: 1, qam: 1, qct: 1, qht: 1, qst: 1, qbo: 1 };
      function isTranslation(article, main) {
        const all = article.textContent || '';
        const at = all.search(translated);
        if (at >= 0) {
          // The language named next to the label.
          const label = all.slice(Math.max(0, at - 24), at + 48);
          return !keptOrigin.test(label);
        }
        const lang = (main.getAttribute('lang') || '').toLowerCase();
        return !!lang && !neutralLangs[lang] && isJapanese(main.textContent);
      }
      function keep(article) {
        if (article.querySelector('[data-testid="placementTracking"]')) { return false; }
        const texts = article.querySelectorAll('[data-testid="tweetText"]');
        // Only pictures or a video: nothing to read.
        if (!texts.length) { return false; }
        const main = texts[0];
        if (isTranslation(article, main)) { return false; }
        return main.getAttribute('lang') === 'ja' || isJapanese(main.textContent);
      }
      // X's offers to translate a post or a bio into the UI's language.
      const translateLabel = /^(Translate post|Translate bio|Translate|Show translation|Rate this translation|ポストを翻訳|自己紹介を翻訳|翻訳を表示|翻訳する)$/i;
      // Buttons known only by their label: share and Grok on each post.
      const ariaHidden = /^(Share post|Share|ポストを共有|共有|Grok actions|Grok|Grokのアクション|Grokに説明してもらう|Explain this post)$/i;
      function hideTranslateButtons(root) {
        // Each button is looked at once.
        root.querySelectorAll('button:not([data-iroha-t]), [role="button"]:not([data-iroha-t])').forEach(function (button) {
          const label = (button.textContent || '').trim();
          const aria = (button.getAttribute('aria-label') || '').trim();
          const hide = (label.length <= 30 && translateLabel.test(label)) || (aria.length <= 30 && ariaHidden.test(aria));
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
        if (!tablist.closest('.iroha-x-header')) {
          let node = tablist;
          while (node && node !== column) {
            const position = getComputedStyle(node).position;
            if (position === 'sticky' || position === 'fixed') { break; }
            node = node.parentElement;
          }
          // No sticky container found: hide the tabs themselves.
          (node && node !== column ? node : tablist).classList.add('iroha-x-header');
        }
        // おすすめ, or フォロー中 when that was chosen from the app's menu.
        const tabs = tablist.querySelectorAll('[role="tab"]');
        const wanted = tabs[window.__irohaFollowingFeed ? 1 : 0];
        if (wanted && wanted.getAttribute('aria-selected') !== 'true' && Date.now() - lastTabClick > 2000) {
          lastTabClick = Date.now();
          wanted.click();
        }
      }
      // Other pages' top bar (back arrow and title): the column's first
      // sticky block, a few levels down.
      function pageHeader(column) {
        let node = column;
        for (let depth = 0; depth < 6 && node; depth++) {
          node = node.firstElementChild;
          if (!node) { return; }
          if (node.classList.contains('iroha-x-header')) { return; }
          const position = getComputedStyle(node).position;
          if (position === 'sticky' || position === 'fixed') {
            // Never a header that holds the posts themselves.
            if (!node.querySelector('article')) { node.classList.add('iroha-x-header'); }
            return;
          }
        }
      }
      // A post's action bar without the gaps the hidden buttons left: a
      // slot holding nothing but hidden buttons goes too, so the rest
      // spread evenly. Bars are looked at again only when they change.
      const goneButtons = '[data-testid="retweet"], [data-testid="unretweet"], [data-iroha-t="1"]';
      // A copy-link button in each post's action bar, where share was: the
      // app copies the post's address on an embed-friendly site.
      const linkIcon = '<svg viewBox="0 0 24 24" width="18.75" height="18.75" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07l-1.5 1.5"/><path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07l1.5-1.5"/></svg>';
      const doneIcon = '<svg viewBox="0 0 24 24" width="18.75" height="18.75" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
      function statusPath(article) {
        const links = article.querySelectorAll('a[href*="/status/"]');
        let fallback = null;
        for (const link of links) {
          const match = (link.getAttribute('href') || '').match(/^\\/([^\\/]+)\\/status\\/(\\d+)/);
          if (!match) { continue; }
          // The post's own link is the one around its time.
          if (link.querySelector('time')) { return '/' + match[1] + '/status/' + match[2]; }
          if (!fallback) { fallback = '/' + match[1] + '/status/' + match[2]; }
        }
        const here = location.pathname.match(/^\\/([^\\/]+)\\/status\\/(\\d+)/);
        return fallback || (here ? here[0] : null);
      }
      function addShareButtons(column) {
        column.querySelectorAll('article [role="group"]:not([data-iroha-share])').forEach(function (group) {
          group.dataset.irohaShare = '1';
          const slot = document.createElement('div');
          slot.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;flex:1 1 0;';
          const button = document.createElement('button');
          button.type = 'button';
          button.setAttribute('aria-label', 'リンクをコピー');
          button.dataset.irohaT = '0';
          button.style.cssText = 'display:flex;align-items:center;justify-content:center;background:none;border:0;padding:0;margin:0;height:34px;min-width:34px;color:rgb(113,118,123);cursor:pointer;-webkit-tap-highlight-color:transparent;';
          button.innerHTML = linkIcon;
          button.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            const article = group.closest('article');
            const path = article ? statusPath(article) : null;
            if (!path) { return; }
            try { webkit.messageHandlers.irohaShare.postMessage({ path: path }); } catch (e) { return; }
            button.innerHTML = doneIcon;
            button.style.color = 'rgb(29,155,240)';
            setTimeout(function () { button.innerHTML = linkIcon; button.style.color = 'rgb(113,118,123)'; }, 1400);
          }, true);
          slot.appendChild(button);
          group.appendChild(slot);
          if (location.pathname === '/home') { addNotInterested(group); }
        });
      }
      // X's own 興味がない, from the post's ⋯ menu (hidden here): the menu is
      // opened out of sight, its item pressed, and the post leaves the page.
      function menusHidden(on) {
        let style = document.getElementById('iroha-x-menu');
        if (on && !style) {
          style = document.createElement('style');
          style.id = 'iroha-x-menu';
          style.textContent = '[role="menu"], [data-testid="Dropdown"], [data-testid="mask"] { opacity: 0 !important; }';
          document.head.appendChild(style);
        } else if (!on && style) {
          style.remove();
        }
      }
      function notInterested(article, button) {
        const caret = article.querySelector('[data-testid="caret"]');
        if (!caret) { return; }
        menusHidden(true);
        caret.click();
        let tries = 0;
        const timer = setInterval(function () {
          tries += 1;
          const items = Array.prototype.slice.call(document.querySelectorAll('[role="menuitem"]'));
          const item = items.filter(function (i) { return /興味がない|Not interested/i.test(i.textContent); })[0];
          if (!item && tries < 20) { return; }
          clearInterval(timer);
          if (item) {
            item.click();
            cellOf(article).classList.add('iroha-x-gone');
          } else {
            // Not offered here: the menu closes unseen, the button says so.
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            const mask = document.querySelector('[data-testid="mask"]');
            if (mask) { mask.click(); }
            button.style.opacity = '0.3';
          }
          setTimeout(function () { menusHidden(false); }, 300);
        }, 50);
      }
      function addNotInterested(group) {
        const slot = document.createElement('div');
        slot.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;flex:1 1 0;';
        const button = document.createElement('button');
        button.type = 'button';
        button.setAttribute('aria-label', '興味がない');
        button.dataset.irohaT = '0';
        button.style.cssText = 'display:flex;align-items:center;justify-content:center;background:none;border:0;padding:0;margin:0;height:34px;min-width:34px;color:rgb(113,118,123);cursor:pointer;-webkit-tap-highlight-color:transparent;';
        button.innerHTML = '<svg viewBox="0 0 24 24" width="18.75" height="18.75" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg>';
        button.addEventListener('click', function (event) {
          event.preventDefault();
          event.stopPropagation();
          const article = group.closest('article');
          if (article) { notInterested(article, button); }
        }, true);
        slot.appendChild(button);
        group.appendChild(slot);
      }
      function tidyActions(column) {
        column.querySelectorAll('[role="group"]').forEach(function (group) {
          const signature = group.childElementCount + ':' + group.querySelectorAll('button, [role="button"]').length;
          if (group.dataset.irohaTidy === signature) { return; }
          group.dataset.irohaTidy = signature;
          Array.prototype.forEach.call(group.children, function (slot) {
            const buttons = slot.querySelectorAll('button, [role="button"]');
            if (!buttons.length) { return; }
            const all = Array.prototype.every.call(buttons, function (b) { return b.matches(goneButtons); });
            slot.classList.toggle('iroha-x-gone', all);
          });
        });
      }
      // The reply box under an opened post.
      function hideComposer(column) {
        const box = column.querySelector('[data-testid="tweetTextarea_0"]:not([data-iroha-c])');
        if (!box) { return; }
        box.dataset.irohaC = '1';
        const cell = box.closest('[data-testid="cellInnerDiv"]');
        if (cell) { cell.classList.add('iroha-x-composer'); }
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
        if (column) {
          hideTranslateButtons(column);
          addShareButtons(column);
          tidyActions(column);
          if (home) { homeHeader(column); } else { pageHeader(column); }
          hideComposer(column);
        }
        // The account's own likes show as they are: they were chosen.
        const on = !!window.__irohaJapaneseOnly && !/\\/likes\\/?$/.test(location.pathname);
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
