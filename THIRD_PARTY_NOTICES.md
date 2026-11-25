# Third-Party Notices

PhotoSyncer uses the following open-source Swift packages (resolved via Swift Package Manager). If you distribute compiled binaries of PhotoSyncer, include this file alongside the distribution.

---

## 1. Citadel (`https://github.com/orlandos-nl/Citadel`)
**License: MIT**

```text
MIT License

Copyright (c) 2022 Orlandos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

`CCitadelBcrypt` includes OpenBSD Blowfish / `bcrypt-pbkdf` components:
```text
Blowfish - a fast block cipher designed by Bruce Schneier
Copyright 1997 Niels Provos <provos@physnet.uni-hamburg.de>
All rights reserved.
This product includes software developed by Niels Provos.
```

---

## 2. BigInt (`https://github.com/attaswift/BigInt`)
**License: MIT**

```text
Copyright (c) 2016-2017 Károly Lőrentey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. Apple Swift Packages (Apache License 2.0)

The following packages are licensed under the **Apache License, Version 2.0** (full license text in [LICENSE](./LICENSE)):

- **SwiftNIO** (`https://github.com/apple/swift-nio`) — Copyright 2017–2024 The SwiftNIO Project
- **SwiftNIO SSH** (`https://github.com/Wellz26/swift-nio-ssh`, derived from `https://github.com/apple/swift-nio-ssh`) — Copyright The SwiftNIO SSH Project
- **SwiftCrypto** (`https://github.com/apple/swift-crypto`) — Copyright 2019–2024 The SwiftCrypto Project (embeds BoringSSL components)
- **SwiftASN1** (`https://github.com/apple/swift-asn1`) — Copyright 2022–2024 The SwiftASN1 Project
- **SwiftLog** (`https://github.com/apple/swift-log`) — Copyright 2018–2024 The SwiftLog Project
- **Swift Collections** (`https://github.com/apple/swift-collections`) — Copyright Apple Inc. and the Swift project authors
- **Swift Atomics** (`https://github.com/apple/swift-atomics`) — Copyright Apple Inc. and the Swift project authors
- **Swift System** (`https://github.com/apple/swift-system`) — Copyright Apple Inc. and the Swift project authors

### SwiftNIO `NOTICE`
```text
                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:
  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

- Influenced by Netty (Apache License 2.0, https://netty.io)
- Contains NodeJS's llhttp (MIT License, https://github.com/nodejs/llhttp)
- Contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET (MIT License, https://github.com/18sg/uSHET)
- Contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995-1998 WIDE Project, BSD-3-Clause)
- Contains derivations from swift-extras-base64, AsyncHTTPClient, SwiftCertificates, Swift System, and Swift Package Manager (Apache License 2.0)
```

### SwiftCrypto `NOTICE`
```text
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:
  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

- Contains test vectors from Google's wycheproof project (Apache License 2.0, https://github.com/google/wycheproof)
- Contains derivations of files from SwiftNIO (Apache License 2.0, https://github.com/apple/swift-nio)
- Embeds BoringSSL (ISC / OpenSSL / MIT licenses, https://boringssl.googlesource.com/boringssl/)
```

### SwiftASN1 `NOTICE`
```text
                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:
  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

- Contains derivations of scripts from SwiftNIO and Swift OpenAPI Generator (Apache License 2.0)
```

### SwiftLog `NOTICE`
```text
                            The SwiftLog Project
                            ========================

Please visit the SwiftLog web site for more information:
  * https://github.com/apple/swift-log

Copyright 2018, 2019 The SwiftLog Project

- Contains derivations of the lock implementation and scripts from SwiftNIO (Apache License 2.0)
```
