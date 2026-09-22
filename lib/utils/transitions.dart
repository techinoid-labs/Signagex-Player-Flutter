/// Maps a transition name from the CMS onto the animations the player
/// implements.
///
/// The switches in campaign_view and play_list_view were written against
/// names the CMS does not produce. They expect fadeIn / slideOverLeftToRight
/// / slideInOutBottomToTop and the like, while the CMS emits:
///
///   campaign  : no-transition | fade | slide
///   playlist  : fade-in | fade-out | slide | none
///
/// and payloads have been seen carrying "Fade" capitalised. So every
/// transition fell through to the default and nothing animated, whichever
/// option was selected. Comparison here ignores case, spaces, hyphens and
/// underscores.
///
/// fade-out renders as a fade: both switches drive an AnimatedSwitcher, so
/// the outgoing item already fades out as the incoming one fades in. A plain
/// "slide" has no direction, so it gets the conventional one -- new content
/// entering from the right.
///
/// An unrecognised name returns 'none' rather than something arbitrary: a
/// transition nobody asked for is more jarring than none at all.
///
/// Lives in its own file rather than beside one of the switches so both can
/// use it without importing each other's widget tree, and so it can be
/// tested without pulling in the webview and video plugins.
String normalizeTransitionName(String? raw) {
  final key = (raw ?? '')
      .trim()
      .toLowerCase()
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll(' ', '');

  switch (key) {
    case '':
    case 'none':
    case 'notransition':
      return 'none';
    case 'fade':
    case 'fadein':
    case 'fadeout':
      return 'fadeIn';
    case 'slide':
    case 'slidein':
      return 'slideOverRightToLeft';
    case 'slideoverlefttoright':
      return 'slideOverLeftToRight';
    case 'slideoverrighttoleft':
      return 'slideOverRightToLeft';
    case 'slideovertoptobottom':
      return 'slideOverTopToBottom';
    case 'slideoverbottomtotop':
      return 'slideOverBottomToTop';
    case 'slideinoutlefttoright':
      return 'slideInOutLeftToRight';
    case 'slideinoutrighttoleft':
      return 'slideInOutRightToLeft';
    case 'slideinouttoptobottom':
      return 'slideInOutTopToBottom';
    case 'slideinoutbottomtotop':
      return 'slideInOutBottomToTop';
    default:
      return 'none';
  }
}
