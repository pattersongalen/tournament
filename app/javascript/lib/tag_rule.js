// The one "is the selected species the tagged one" rule shared by the catch
// log form and the organizer/judge editors' tag-field toggle. Both callers
// pass a Stimulus String value, which defaults to "" when the attribute is
// absent, and an empty tagged id (species not seeded) never matches, so the
// tag field stays hidden.
export function isTaggedSpecies(selectedSpeciesId, taggedSpeciesId) {
  return taggedSpeciesId !== ""
      && String(selectedSpeciesId) === String(taggedSpeciesId)
}
