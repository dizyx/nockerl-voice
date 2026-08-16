# Third-Party Licenses

Nockerl Voice is released under the [MIT License](LICENSE). It bundles the following
third-party components:

## LAME (libmp3lame)

Used for on-device MP3 encoding of recorded audio (macOS has no native MP3 encoder).
LAME is included as a source-compiled Swift Package Manager dependency
([Phisto/swift-lame](https://github.com/Phisto/swift-lame), which packages LAME 3.100).

- Project: LAME (LAME Ain't an MP3 Encoder) - https://lame.sourceforge.io
- License: GNU Lesser General Public License (LGPL)

The LGPL requires that users be able to relink the application against a modified
version of LAME. Because Nockerl Voice is fully open-source and LAME is pulled as a
public source dependency, anyone can rebuild the entire application from source, which
satisfies that requirement. Nockerl Voice's own source stays under the MIT License;
LAME stays under the LGPL. The full LGPL text is at
https://www.gnu.org/licenses/lgpl-3.0.html.

## Sparkle

Used for over-the-air app updates. Sparkle is the standard updater for notarized, directly
distributed Mac apps, and it is included as a Swift Package Manager dependency
([sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)). Its framework
binary is embedded in the shipped app, so its license travels with it.

- Project: Sparkle - https://sparkle-project.org
- License: MIT (with additional third-party notices in the project's own LICENSE file)

Sparkle bundles a small number of components under permissive licenses of their own,
including bsdiff (BSD 2-Clause) and Google Toolbox for Mac (Apache 2.0). The complete text
of Sparkle's license and those notices ships in the Sparkle repository at
https://github.com/sparkle-project/Sparkle/blob/main/LICENSE.

## Outfit & Space Mono (fonts)

Nockerl Voice displays text in the **Outfit** and **Space Mono** typefaces. These
arrive transitively through the **NockerlDesign** Swift package dependency, which ships
the font **binaries** (`.ttf`) inside its resource bundle. Because Nockerl Voice
redistributes those binaries, the full font license travels with it.

- Outfit - Copyright 2021 The Outfit Project Authors (https://github.com/Outfitio/Outfit-Fonts) - SIL Open Font License 1.1
- Space Mono - Copyright 2016 The Space Mono Project Authors (https://github.com/googlefonts/spacemono) - SIL Open Font License 1.1

Both fonts are licensed under the SIL Open Font License, Version 1.1. Their two license
files ship **identical** license text and differ **only** in the copyright-notice line,
so the license is reproduced once below, preceded by both copyright notices.

```
Copyright 2021 The Outfit Project Authors (https://github.com/Outfitio/Outfit-Fonts)
Copyright 2016 The Space Mono Project Authors (https://github.com/googlefonts/spacemono)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
