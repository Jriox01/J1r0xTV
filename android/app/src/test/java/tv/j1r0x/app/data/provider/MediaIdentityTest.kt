package tv.j1r0x.app.data.provider

import org.junit.Assert.assertEquals
import org.junit.Test

class MediaIdentityTest {
    @Test
    fun lookupCandidatesUseStableIdsBeforeExactTitles() {
        val candidates = MediaIdentity(
            tmdbId = "tmdb-3",
            imdbId = "tt0000001",
            kinopoiskId = "kp-2",
            title = "Локальное название",
            originalTitle = "Original title",
            year = "2026",
            mediaType = MediaType.MOVIE,
        ).lookupCandidates()

        assertEquals(
            listOf(
                MediaIdentityKey.IMDB,
                MediaIdentityKey.KINOPOISK,
                MediaIdentityKey.TMDB,
                MediaIdentityKey.ORIGINAL_TITLE_AND_YEAR,
                MediaIdentityKey.TITLE_AND_YEAR,
            ),
            candidates.map { it.key },
        )
    }

    @Test
    fun titleFallbackIsNotEmittedWithoutExactYear() {
        val candidates = MediaIdentity(
            tmdbId = "42",
            title = "Ambiguous title",
            originalTitle = "Ambiguous original",
            mediaType = MediaType.TV,
        ).lookupCandidates()

        assertEquals(listOf(MediaIdentityKey.TMDB), candidates.map { it.key })
    }
}
