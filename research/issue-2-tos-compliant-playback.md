## Main finding

As of 12 August 2026, I did not find a public Spotify SDK that lets a native macOS app receive and play the catalog locally with a general, documented authorization.

Official paths split as follows:

- Web Playback SDK: playback inside a compatible browser. Spotify does not document WKWebView, Electron, or other embedded webviews as supported environments.
- Web API: metadata, state, and commands against Spotify or a Spotify Connect device. It does not deliver a raw audio stream to the app.
- iOS SDK: the current SDK is App Remote and controls the installed Spotify app. Earlier mobile streaming SDKs were withdrawn.
- Partner/eSDK: integrated playback exists for approved hardware, with application, NDA, certification, and a distribution agreement. It is not a self-service path for a desktop app.
- Written agreement: the terms leave room for products or devices approved in writing, but there is no automatic permission for an arbitrary native app.

## Web Playback SDK and WKWebView

The [official Web Playback SDK documentation](https://developer.spotify.com/documentation/web-playback-sdk) describes it as a client-side JavaScript library that creates a local Spotify Connect device in the browser. It lists Chrome, Firefox, Safari, and Edge on desktop, and explains EME, autoplay, and iframe requirements. It does not list WKWebView, embedded webviews, Electron, or CEF.

The [Player reference](https://developer.spotify.com/documentation/web-playback-sdk/reference) requires a Premium user and uses the browser's content protection. In practice, protected playback depends on the available CDM/EME: Spotify documents Widevine for some browsers, while WebKit uses Apple's mechanisms. WebKit having EME and FairPlay support does not mean the Web Playback SDK is supported inside WKWebView.

Conclusion: a WKWebView prototype might work on some versions, but there is no official support or guarantee of compatibility, authentication, DRM, or lifecycle. For a production app I would not treat it as a supported path. A Safari or Chrome window is closer to the documented path, although it stops being native playback inside the app.

## Web API: remote control, not local audio

The official [Start/Resume Playback](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback), [Get Playback State](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback), [Get Available Devices](https://developer.spotify.com/documentation/web-api/reference/get-the-users-available-devices), and [Transfer Playback](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback) endpoints can start, pause, query, and transfer playback to an active device. They require the corresponding scopes and, for on-demand playback, Premium.

These endpoints send commands and return state, tracks, progress, and devices. The documented API does not return a catalog audio stream to the app. That is the right basis for a remote mode that controls the official Spotify app or a Connect device.

The [Developer Policy](https://developer.spotify.com/policy) still applies: metadata and artwork must be shown, streaming and monetization restrictions apply, and replicating or replacing a core Spotify experience without prior written permission is prohibited.

## iOS SDK

Spotify announced that the old mobile streaming SDKs stopped working and asked for them to be removed before 1 September 2022 in its [official update](https://developer.spotify.com/blog/2022-07-15-mobile-streaming-sdks-update). The current SDK is App Remote: the [iOS documentation](https://developer.spotify.com/documentation/ios) and its [official repository](https://github.com/spotify/ios-sdk) explain that the app controls Spotify installed on the same device, and that Spotify does the heavy lifting of playback, networking, and cache.

There is no official documentation for using that SDK as an audio engine on macOS, Mac Catalyst, or a native desktop app. An iOS app being able to run on Apple silicon does not make that integration a supported macOS SDK.

## Partner programs, eSDK, and DRM

The official integrated-playback path that does appear in the documentation is [Commercial Hardware](https://developer.spotify.com/documentation/commercial-hardware). Spotify states that it accepts applications from organizations, not individuals, and that the process includes evaluation, NDA, eSDK access, Certomato tests, certification, and a distribution agreement; see also the [onboarding process](https://developer.spotify.com/documentation/commercial-hardware/onboarding).

In that context, [Media Delivery](https://developer.spotify.com/documentation/commercial-hardware/implementation/guides/media-delivery) delivers data to partner code so the partner implements the decoder and audio output. It also warns that DRM support in the application covers only some formats. It is a negotiated path for approved products, not a public library any macOS app can download.

Widevine also does not solve authorization. [Google's documentation](https://developers.google.com/widevine/drm/overview) shows Widevine support in Chrome and CEF/Electron, but not in desktop Safari, and requires license agreements for Widevine products. A generic CDM or DRM license does not grant access to Spotify's catalog or replace Spotify's permission. On Apple, [WebKit documents EME](https://webkit.org/blog/8718/new-webkit-features-in-safari-12-1/) and Apple documents FairPlay for its devices and Safari; that is not Web Playback SDK support inside WKWebView.

The [Developer Terms](https://developer.spotify.com/terms) include desktop computers among generally approved devices, but they also prohibit reverse engineering, code extraction, stream ripping, and permanent copies, among other things. The correct reading is not that all desktop playback is automatically illegal, but that a local implementation needs an authorized basis; making it technically play is not enough.

## What other clients do

| Client | How it gets playback | What it shows |
| --- | --- | --- |
| [Psst](https://github.com/jpochyla/psst) | Native GUI client in Rust; its core fetches audio over HTTPS/CDN, decodes it, and delivers it to output. It is inspired by librespot and still states that remote Spotify Connect is not supported. | Local playback is technically possible, but the project does not document Spotify authorization. |
| [ncspot](https://github.com/hrkfdn/ncspot) | Terminal client in Rust based on [librespot](https://github.com/librespot-org/librespot). macOS and Premium are compatible. | It is an unofficial receiver/client based on a community implementation. |
| [spotify_player](https://github.com/aome510/spotify-player) | Uses the Web API for REST, library, and control; creates a separate librespot session for streaming and Connect. Streaming can be disabled at compile time. | The Web API + local engine split is a practical architecture, not proof of authorization. |

In the repositories reviewed there is no public evidence of a partner agreement with Spotify. That is why it is not useful to conclude that all of them “violate the ToS” as a proven fact; it is fair to conclude that they are not a public path supported by Spotify's documentation and that they carry legal, blocking, and maintenance risk. The ToS also prohibit reverse engineering, ripping, and permanent copies.

## Recommendation for spotify-lite

The most sensible architecture is hybrid, with a clear legal and technical boundary:

1. Official mode by default: OAuth PKCE, Web API for search, metadata, library, and state, and transfer/remote-control commands. Audio output stays in Spotify or on an authorized Connect device.
2. Optional backend: an external librespot process, isolated behind a PlayerEngine interface, only if the product explicitly accepts that it is experimental, unofficial, and outside the supported path. Keeping it opt-in and removable avoids coupling the rest of the app to that risk, but isolating it does not change its legal status.
3. If the requirement is local playback inside the app and strict compliance: request a written agreement from Spotify or explore the eSDK/partner program. Without that approval, do not promise authorized native playback.

So the answer is: yes, Web API + optional external librespot is the best technical compromise for a project that wants both modes; no, the full set should not be described as “ToS-compliant”. Remote mode is the lower-risk, documented base. Local playback with librespot is an optional decision with its own risk.

This is a technical analysis of current public documentation, not legal advice.
