/*
 * MD Vieditor: связка визуального редактора Vditor с программой.
 * Программа вызывает window.mdOpen(...), а изменения получает через сообщения
 * window.webkit.messageHandlers.mdEditor.
 */
(function () {
  'use strict';

  // Папка с файлами Vditor лежит рядом с этой страницей.
  var CDN = new URL('vditor', location.href).href.replace(/\/$/, '');

  var editor = null;
  var baseline = null;   // Markdown после открытия или последнего сохранения
  var postTimer = null;

  function post(message) {
    try {
      window.webkit.messageHandlers.mdEditor.postMessage(message);
    } catch (e) {
      (window.__mdMessages = window.__mdMessages || []).push(message);
    }
  }

  function prefersDark() {
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  function applyTheme() {
    if (!editor) return;
    var dark = prefersDark();
    editor.setTheme(dark ? 'dark' : 'classic', dark ? 'dark' : 'light', dark ? 'github-dark' : 'github');
  }

  function setBase(href) {
    var base = document.querySelector('base');
    if (!base) {
      base = document.createElement('base');
      document.head.insertBefore(base, document.head.firstChild);
    }
    base.setAttribute('href', href);
  }

  // Сообщает программе текущий Markdown и то, отличается ли он от сохранённого.
  function reportChange() {
    if (!editor) return;
    var markdown = editor.getValue();
    post({ type: 'changed', markdown: markdown, dirty: markdown !== baseline });
  }

  function scheduleReport() {
    clearTimeout(postTimer);
    postTimer = setTimeout(reportChange, 250);
  }

  function disableSpellcheck() {
    var areas = document.querySelectorAll('#editor [contenteditable]');
    for (var i = 0; i < areas.length; i++) areas[i].setAttribute('spellcheck', 'false');
  }

  function openLink(element) {
    if (!element) return;
    var href = element.getAttribute && element.getAttribute('href');
    if (!href) href = (element.textContent || '').trim();
    if (href) post({ type: 'openLink', href: href });
  }

  // Кнопка панели: подсказка появляется под кнопкой (над кнопкой её срезал бы край окна).
  function item(name, extra) {
    var config = { name: name, tipPosition: 's' };
    for (var key in extra) config[key] = extra[key];
    return config;
  }

  // Сочетания клавиш Vditor, которые перебивали бы меню программы, заменены:
  // ⌘H (скрыть программу), ⌘O (открыть), ⌘G (найти далее), ⌘M (свернуть окно).
  var TOOLBAR = [
    item('headings', { hotkey: '' }),
    item('bold'), item('italic'), item('strike'), item('link'), '|',
    item('list'), item('ordered-list', { hotkey: '⇧⌘L' }), item('check'), item('outdent'), item('indent'), '|',
    item('quote'), item('line'), item('code'), item('inline-code', { hotkey: '⌥⌘C' }), item('table', { hotkey: '⌥⌘T' }), '|',
    item('undo'), item('redo'), '|', item('edit-mode'), item('outline')
  ];

  // Плавающая панель у текущего блока (вверх, вниз, корзинка): если на левом поле хватает места,
  // она стоит слева от строки, а не над ней. Широкие панели (таблица, код) остаются над блоком.
  var popoverObserver = null;

  function placePopover() {
    var popover = document.querySelector('.vditor-wysiwyg > .vditor-panel--none');
    var text = document.querySelector('.vditor-wysiwyg > pre.vditor-reset');
    if (!popover || !text) return;
    var holder = popover.parentElement;
    if (popover.style.display === 'none') {
      popover.classList.remove('md-popover-side');
      return;
    }
    var margin = parseFloat(getComputedStyle(text).paddingLeft) || 0;
    var textLeft = text.offsetLeft + margin;
    var width = popover.offsetWidth;
    var height = popover.offsetHeight;
    var fields = Array.prototype.some.call(popover.querySelectorAll('input, select, textarea'), function (el) {
      return el.offsetParent !== null;
    });
    var side = !fields && width + 16 <= margin;
    var dx = 0;
    var dy;
    if (side) {
      // правый край панели — на 14 px левее начала текста; по высоте — у первой строки блока
      dx = textLeft - popover.offsetLeft - width - 14;
      dy = 21 + Math.round((24 - height) / 2);
    } else {
      // над блоком целиком, но не выше верхнего края области текста
      dy = Math.max(-popover.offsetTop, 21 - height - 4);
    }
    popover.classList.toggle('md-popover-side', side);
    holder.style.setProperty('--md-popover-dx', dx + 'px');
    holder.style.setProperty('--md-popover-dy', dy + 'px');
  }

  function watchPopover() {
    if (popoverObserver) popoverObserver.disconnect();
    var popover = document.querySelector('.vditor-wysiwyg > .vditor-panel--none');
    if (!popover || !window.MutationObserver) return;
    popoverObserver = new MutationObserver(placePopover);
    popoverObserver.observe(popover, { attributes: true, attributeFilter: ['style'], childList: true, subtree: true });
  }

  window.addEventListener('resize', placePopover);

  // Свои цвета фона и текста (выбираются в Settings). null — цвета темы.
  var customColors = { background: null, text: null };

  function applyColors() {
    var style = document.getElementById('md-custom-colors');
    if (!style) {
      style = document.createElement('style');
      style.id = 'md-custom-colors';
      document.head.appendChild(style);
    }
    var bg = customColors.background;
    var fg = customColors.text;
    var css = '';
    if (bg) {
      css += 'html, body, #editor .vditor, .vditor-content, .vditor-wysiwyg, .vditor-ir, .vditor-sv,'
        + ' .vditor-wysiwyg > pre.vditor-reset, .vditor-ir > pre.vditor-reset, pre.vditor-sv, .vditor-toolbar'
        + ' { background-color: ' + bg + ' !important; }\n';
    }
    if (fg) {
      css += '.vditor-reset, pre.vditor-sv, .vditor-reset h1, .vditor-reset h2, .vditor-reset h3,'
        + ' .vditor-reset h4, .vditor-reset h5, .vditor-reset h6 { color: ' + fg + ' !important; }\n'
        + '.vditor-toolbar .vditor-toolbar__item > button { color: ' + fg + ' !important; opacity: 0.75; }\n'
        + '.vditor-toolbar .vditor-toolbar__item > button:hover { opacity: 1; }\n';
    }
    if (bg || fg) {
      css += '.vditor-reset table tr, .vditor-reset table tbody tr:nth-child(2n) { background-color: transparent !important; }\n'
        + '.vditor-reset table th { background-color: color-mix(in srgb, currentColor 7%, transparent) !important; }\n'
        + '.vditor-reset table td, .vditor-reset table th { border-color: color-mix(in srgb, currentColor 25%, transparent) !important; }\n'
        + '.vditor-toolbar { border-bottom-color: color-mix(in srgb, currentColor 15%, transparent) !important; }\n'
        + '.vditor-reset h1, .vditor-reset h2 { border-bottom-color: color-mix(in srgb, currentColor 18%, transparent) !important; }\n'
        + '.vditor-reset hr { background-color: color-mix(in srgb, currentColor 25%, transparent) !important; }\n';
    }
    style.textContent = css;
  }

  window.mdSetColors = function (background, text) {
    customColors.background = background || null;
    customColors.text = text || null;
    applyColors();
    return true;
  };

  window.mdOpen = function (markdown, baseHref, mode) {
    setBase(baseHref || 'mdfile:///');
    if (editor) {
      editor.destroy();
      editor = null;
    }
    var dark = prefersDark();
    return new Promise(function (resolve) {
      editor = new Vditor('editor', {
        cdn: CDN,
        lang: 'en_US',
        mode: mode || 'wysiwyg',
        value: markdown || '',
        height: '100%',
        cache: { enable: false },
        toolbar: TOOLBAR,
        toolbarConfig: { pin: true },
        theme: dark ? 'dark' : 'classic',
        icon: 'ant',
        placeholder: 'Empty document. Start typing…',
        counter: { enable: false },
        resize: { enable: false },
        outline: { enable: false, position: 'left' },
        preview: {
          mode: 'editor',
          maxWidth: 100000,
          theme: { current: dark ? 'dark' : 'light', path: CDN + '/dist/css/content-theme' },
          hljs: { enable: true, style: dark ? 'github-dark' : 'github', lineNumber: false },
          math: { engine: 'KaTeX' },
          markdown: {
            sanitize: true,
            autoSpace: false,
            fixTermTypo: false,
            paragraphBeginningSpace: false,
            toc: false,
            footnotes: true,
            mark: false,
            codeBlockPreview: true,
            mathBlockPreview: true
          },
          actions: []
        },
        link: { isOpen: false, click: openLink },
        image: { isPreview: true },
        input: scheduleReport,
        after: function () {
          baseline = editor.getValue();
          disableSpellcheck();
          var area = document.querySelector('#editor');
          area.addEventListener('input', scheduleReport, true);
          watchPopover();
          applyColors();
          resolve({ mode: editor.getCurrentMode(), length: baseline.length });
        }
      });
    });
  };

  window.mdGetMarkdown = function () {
    return editor ? editor.getValue() : null;
  };

  // После сохранения: текущий текст становится «сохранённым».
  window.mdMarkSaved = function (markdown) {
    baseline = (typeof markdown === 'string') ? markdown : (editor ? editor.getValue() : baseline);
    reportChange();
  };

  // Для самопроверки после сборки: дописывает строку, как будто её набрали.
  window.mdSelfTestEdit = function () {
    if (!editor) return false;
    editor.setValue(editor.getValue() + '\n\nСамопроверка ввода.\n', false);
    scheduleReport();
    return true;
  };

  // После «Вернуть к сохранённому».
  window.mdSetMarkdown = function (markdown, baseHref) {
    if (!editor) return;
    if (baseHref) setBase(baseHref);
    editor.setValue(markdown || '', true);
    baseline = editor.getValue();
    disableSpellcheck();
  };

  window.mdSetBase = function (baseHref) {
    if (baseHref) setBase(baseHref);
  };

  window.mdGetMode = function () {
    return editor ? editor.getCurrentMode() : null;
  };

  window.mdSetMode = function (mode) {
    if (!editor) return null;
    if (editor.getCurrentMode() !== mode) {
      var button = document.querySelector('.vditor-toolbar [data-mode="' + mode + '"]');
      if (button) button.click();
      disableSpellcheck();
      watchPopover();
    }
    return editor.getCurrentMode();
  };

  // Кнопки панели инструментов: undo, redo, bold, italic, strike, link, list,
  // ordered-list, check, quote, line, code, inline-code, table.
  window.mdCommand = function (name) {
    if (!editor) return false;
    var button = document.querySelector('.vditor-toolbar [data-type="' + name + '"]');
    if (!button) return false;
    button.click();
    scheduleReport();
    return true;
  };

  window.mdHeading = function (level) {
    if (!editor) return false;
    var button = document.querySelector('.vditor-toolbar [data-tag="h' + level + '"]');
    if (!button) return false;
    button.click();
    scheduleReport();
    return true;
  };

  if (window.matchMedia) {
    var query = window.matchMedia('(prefers-color-scheme: dark)');
    if (query.addEventListener) query.addEventListener('change', applyTheme);
  }

  // Режим, выбранный кнопкой на панели, программа запоминает для новых окон.
  document.addEventListener('click', function (event) {
    var target = event.target && event.target.closest ? event.target.closest('[data-mode]') : null;
    if (target && editor) {
      setTimeout(function () {
        disableSpellcheck();
        post({ type: 'mode', mode: editor.getCurrentMode() });
      }, 0);
    }
  }, true);
})();
