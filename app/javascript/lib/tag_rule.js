// The one "is the selected species the tagged one" rule shared by the catch
// log form and the organizer/judge editors' tag-field toggle. An empty tagged
// id (species not seeded) never matches, so the tag field stays hidden.
export function isTaggedSpecies(selectedSpeciesId, taggedSpeciesId) {
  return taggedSpeciesId !== undefined
      && taggedSpeciesId !== ""
      && String(selectedSpeciesId) === String(taggedSpeciesId)
}
