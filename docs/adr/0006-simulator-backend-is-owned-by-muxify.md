# Simulator backend is owned by Muxify

The Simulator Server owns its backend under `Sources/MuxifySimulatorServer/CoreSimulator/`, with the required Objective-C declarations in `Sources/MuxifySimulatorPrivate/`. We keep only discovery, lifecycle, display, input and rotation used by the browser Simulator, rather than retaining a separate vendored engine package and unused capabilities for future upstream updates. We own compatibility fixes and preserve the incorporated code's required copyright and MIT license notices in `Resources/ThirdPartyNotices/Simulator.txt`.

Support targets Xcode 27 and later on a best-effort basis, with required private interfaces checked before connecting rather than a fixed upper-version limit. Detected incompatibility is reported by the Simulator without blocking the desktop Terminal or Browser. Muxify neither closes Apple's Device Hub nor changes Xcode preferences to suppress it.
