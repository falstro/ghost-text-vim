# Ghost Text VIm

A small server script allowing you to use GVIm with Ghost Text Chrome
(or Firefox) extension. It's a standalone script, and will launch new
instances of GVIm each time. It's implemented in TCL because, reasons.

The integration from VIm to Chrome is fairly robust, and will update on
each change as soon as you get back to normal mode. In the other
direction is a bit more shaky, and will only work if VIm is in normal
mode. If you change the text in chrome while in insert mode in VIm,
you'll get a bunch of crap buffer. This is due to the fact that we can
only replace content by sending keys to VIm (and TCL has issues passing
`<ESC>` to the remote commands) rather than using remote expressions.

Anyway, I wrote this for me, drop me a line if you have any issues and I
might invest some more time into making it more user friendly.
