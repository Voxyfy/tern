# Third-party software

Tern itself is licensed under PolyForm Noncommercial 1.0.0 (see LICENSE). The components below are used under
their own, more permissive licenses, which this does not change.

## go-ios

The device helper (`ternd`) is built on [go-ios](https://github.com/danielpaulus/go-ios) by Daniel Paulus,
used under the MIT License. It handles usbmuxd, pairing, the iOS 17+ userspace tunnel, Remote Service
Discovery and the instruments location channel. It is fetched by Go modules at build time
(`scripts/build-ternd.sh`) and is not vendored in this repository.

> MIT License
>
> Copyright (c) 2019 danielpaulus
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation
> the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
> to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions
> of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
> TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
> THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
> CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
> DEALINGS IN THE SOFTWARE.

go-ios itself depends on further MIT, BSD and Apache-2.0 licensed Go modules; see its `go.mod`.

## Sparkle

In-app updates use [Sparkle](https://sparkle-project.org) under the MIT License, fetched by Swift Package
Manager at build time.

## Apple MapKit

Maps, search and directions come from Apple's MapKit framework on macOS. No API key is involved.
