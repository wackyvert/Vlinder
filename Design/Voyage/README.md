# Voyage for Apple TV

Voyage is an optional tvOS tab for browsing Jellyfin movies and shows as cinema islands on a dusk ocean. A fixed horizon, faceted stone platforms, copper screen frames, and reflected poster art create depth without requiring free movement through a room.

Palette: midnight #091A2B, ocean #113B4A, mist #52798C, ivory #F5EFE6, copper #F0A36B. Rounded system type carries title names; standard system text keeps metadata readable at television distance.

## Remote

- Focus Explore title. Left/right moves one title with a short eased transition.
- Select opens the existing item detail screen, with its normal playback controls.
- Move up to switch movie/show libraries; move down for Poster grid.
- Native Menu/Back behavior stays with the navigation stack.
- Reduce Motion removes travel animation. The scene has no automatic camera movement.

## Implementation

`VoyageView.swift` uses the existing LibraryGridModel for alphabetical paging and NavigationRouter for details. `VoyageSceneView.swift` owns an isolated SceneKit world, with no dependency on Atrium or LiveWall. Only seven neighboring islands exist at a time. Leaving islands cancel their artwork jobs; ImageLoader provides the shared image cache. Missing artwork has a title placeholder. Library and initial page failures offer retry; empty libraries have an explicit state.

The feature is compiled only on tvOS. Existing mobile and Mac presentations are unchanged by this addition. No server plugin or server configuration is needed.

## Verification

The VlinderTV simulator build passed and the world rendered real Jellyfin movie artwork. Screenshots were reviewed to correct the original low framing. Repeated directional browsing, selected-title detail navigation, and the downward poster-grid shortcut were exercised with simulator remote input. Physical Apple TV frame rate and Siri Remote touch sensitivity still require device validation.
