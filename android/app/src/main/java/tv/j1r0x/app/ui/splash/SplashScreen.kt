package tv.j1r0x.app.ui.splash

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import tv.j1r0x.app.R
import tv.j1r0x.app.ui.SplashState
import tv.j1r0x.app.ui.common.isTv

@Composable fun SplashScreen(state:SplashState){val config=LocalConfiguration.current;val fraction=if(isTv()).30f else if(config.smallestScreenWidthDp>=600).40f else .55f;Column(Modifier.fillMaxSize().background(Color.Black),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center){AsyncImage(model=R.raw.j1r0x_tv_loading,contentDescription="J1r0x TV loading",contentScale=ContentScale.Fit,modifier=Modifier.fillMaxWidth(fraction).aspectRatio(1.6f));Spacer(Modifier.height(18.dp));Text("J1r0x TV",color=Color.White,fontSize=30.sp);Text("Загрузка...",color=Color.LightGray);Text(state.status,color=Color.Gray,fontSize=13.sp);Spacer(Modifier.height(14.dp));LinearProgressIndicator(color=Color(0xFFE50914),trackColor=Color.DarkGray,modifier=Modifier.fillMaxWidth(if(isTv()).25f else .55f).height(2.dp))}}
