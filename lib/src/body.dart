import 'package:html/dom.dart' show Comment, Element, Node, Text;
import 'package:html/html_escape.dart' show htmlSerializeEscape;

/// Writes the body of a page from an element tree, accepting only content
/// markup.
///
/// An element outside [tags], an element from another namespace (SVG, MathML)
/// or an attribute outside [attributes] (that does not start with `data-` or
/// `aria-`) throws [ArgumentError]. In `href` and `src`, a URL with a scheme
/// other than `http`/`https`, a URL with an authority and no scheme
/// (`//other.site`) and a URL that cannot be parsed only drop the attribute
/// and are reported to `onUrlDropped`, because they usually come from
/// user-entered data. Text and attribute values are escaped; comments are not
/// written.
abstract final class HtmlBodyWriter {
  /// The elements the body accepts.
  static const tags = {
    'a',
    'abbr',
    'address',
    'article',
    'aside',
    'b',
    'blockquote',
    'br',
    'caption',
    'cite',
    'code',
    'data',
    'dd',
    'div',
    'dl',
    'dt',
    'em',
    'figcaption',
    'figure',
    'footer',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'header',
    'hr',
    'i',
    'img',
    'li',
    'main',
    'mark',
    'nav',
    'ol',
    'p',
    'q',
    's',
    'section',
    'small',
    'span',
    'strong',
    'sub',
    'sup',
    'table',
    'tbody',
    'td',
    'tfoot',
    'th',
    'thead',
    'time',
    'tr',
    'u',
    'ul',
    'wbr',
  };

  /// The attributes the body accepts, besides `data-*` and `aria-*`.
  static const attributes = {
    'id',
    'class',
    'lang',
    'dir',
    'title',
    'hidden',
    'role',
    'itemscope',
    'itemprop',
    'itemtype',
    'href',
    'rel',
    'hreflang',
    'target',
    'src',
    'alt',
    'width',
    'height',
    'loading',
    'datetime',
    'value',
    'colspan',
    'rowspan',
    'scope',
    'start',
  };

  static const _void = {'br', 'hr', 'img', 'wbr'};
  static const _urls = {'href', 'src'};
  static const _html = 'http://www.w3.org/1999/xhtml';

  /// Writes [root] and its descendants to [out]. [onUrlDropped] is called with
  /// the tag and the attribute name each time an unsafe `href` or `src` is
  /// dropped.
  static void write(
    Element root,
    StringBuffer out, {
    void Function(String tag, String attribute)? onUrlDropped,
  }) => _node(root, out, onUrlDropped);

  /// Writes [node] to [out] by its type: escaped text, omitted comment,
  /// element through the allowlist.
  static void _node(
    Node node,
    StringBuffer out,
    void Function(String, String)? dropped,
  ) {
    switch (node) {
      case Text():
        out.write(htmlSerializeEscape(node.data));
      case Comment():
        break;
      case Element():
        _element(node, out, dropped);
      default:
        for (final child in node.nodes) {
          _node(child, out, dropped);
        }
    }
  }

  /// Writes [el] to [out], refusing elements and attributes outside the
  /// allowlist.
  static void _element(
    Element el,
    StringBuffer out,
    void Function(String, String)? dropped,
  ) {
    final tag = el.localName!;
    final ns = el.namespaceUri;
    if ((ns != null && ns != _html) || !tags.contains(tag)) {
      throw ArgumentError(
        'Element <$tag> refused in the page body: only content markup is '
        'allowed (HtmlBodyWriter.tags). Scripts, styles and embeds belong in '
        'the app template.',
      );
    }
    out.write('<$tag');
    el.attributes.forEach((key, value) {
      final name = '$key'.toLowerCase();
      if (!attributes.contains(name) &&
          !name.startsWith('data-') &&
          !name.startsWith('aria-')) {
        throw ArgumentError(
          'Attribute "$name" of <$tag> refused in the page body: only '
          'HtmlBodyWriter.attributes, data-* and aria-* are allowed. Event and '
          'style attributes are not.',
        );
      }
      if (_urls.contains(name) && !_safeUrl(value)) {
        dropped?.call(tag, name);
        return;
      }
      out.write(' $name="${htmlSerializeEscape(value, attributeMode: true)}"');
    });
    out.write('>');
    if (_void.contains(tag)) {
      return;
    }
    for (final child in el.nodes) {
      _node(child, out, dropped);
    }
    out.write('</$tag>');
  }

  /// Whether [value] is `http`, `https` or relative without an authority.
  static bool _safeUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    if (!uri.hasScheme) {
      return !uri.hasAuthority;
    }
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}
