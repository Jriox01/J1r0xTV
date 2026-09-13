package tv.j1r0x.app.data.api

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Url

interface ApiService { @GET suspend fun get(@Url url: String): Response<String> }
