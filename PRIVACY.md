# Bambu Bar Privacy Policy

_Last updated: October 26, 2026_

Bambu Bar is a macOS app that shows the status of Bambu Lab 3D printers, as reported by your own Bambuddy server. It is made by an independent developer (NINA LABS, LLC) and is not affiliated with Bambu Lab.

## The short version

Bambu Bar has no app analytics, advertising or tracking. Printer data only travels between your Mac and your Bambuddy server. Direct purchases use our checkout and licensing provider for payment, licensing and customer accounts. The Mac App Store edition uses Apple’s distribution.

## What the app stores, and where

Printer data is stored on your Mac:

- **Your Bambuddy server's address, its printers** (name, IP address, serial number, model, Bambuddy id) and your preferences: in the app's local settings.
- **The Bambuddy API key:** in your macOS keychain. It is only ever sent to that server.
- **Your last few prints** (job name, times, result), used for finish times and notifications: in a file in the app's own container.
- **A snapshot of each printer's status** for the desktop widgets: in a container shared only with Bambu Bar's widget.
Disconnecting from the server in Printers deletes the API key from the keychain.

## Network connections

- **Your Bambuddy server:** Bambu Bar reads printer status from the server you set up (its REST API and a WebSocket, over http or https as you configured it) and sends print commands to it. It doesn't connect to the printers themselves.
- **Optional supporter licenses:** Our licensing provider receives the license key, activation ID and a random installation ID for activation and periodic checks, plus network information such as IP address. The key and validation date are stored in a non-synchronizing Keychain item on this Mac.
- **Updates:** direct copies with an active website supporter license check the latest GitHub release metadata and use a signed update feed hosted on GitHub to install newer versions. Automatic checks can be turned off in Settings. No printer data is sent.
- **Mac App Store:** purchases and updates are managed by Apple.

The app does not use Bambu Lab's cloud services and does not need your Bambu Lab account.

## Data collected by the developer

We receive no printer telemetry or app usage statistics. Our checkout and licensing provider processes purchase details, including email, billing information and license activations, and makes purchase and licensing records available to us. The app never receives payment card details. See [our checkout provider’s privacy policy](https://polar.sh/legal/privacy).

## Children

The app does not profile users or collect printer telemetry, including from children.

## Changes

If this policy changes, the new version will be published at this address with a new date.

## Contact

Questions about privacy: [contact support](https://github.com/rolottr/bambu-bar/issues).
