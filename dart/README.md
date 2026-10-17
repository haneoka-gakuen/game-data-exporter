# Dart inventory projection

`projectThirdPartyInventory` projects Otonote personal growth/inventory JSON and
MoeNotes card-box JSON into the same current-fact candidate used by the TypeScript
exporter. It accepts a decoded JSON map and returns an `InventoryCandidate`, or
`null` for another format. `InventoryImportError.code` uses the exporter's error
codes. `toJson()` emits the candidate DTO; the receiving application assigns its
own candidate ID.

The package has no runtime dependencies. File selection, archive/save decoding,
release-specific range checks, preview, confirmation and persistence belong to
the importing application. Imported account growth includes character ranks,
individual active instrument levels and TGW CARD rank. Notices preserve unknown,
conflicting, review-pending and unsupported facts without inventing values. A
MoeNotes box linked to a separate save raises `box_linked_save_required`.

The TypeScript and Dart projections share the public candidate contract and
producer semantics. A future cross-language core belongs in game-data-exporter;
it does not belong in a renderer or a team-scoring runtime.
