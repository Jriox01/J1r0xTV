package tv.j1r0x.app

import android.os.Bundle
import android.view.Window
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.viewmodel.compose.viewModel
import tv.j1r0x.app.ui.AppViewModel
import tv.j1r0x.app.ui.navigation.J1r0xApp

class MainActivity:ComponentActivity(){
    override fun onCreate(savedInstanceState:Bundle?){installSplashScreen();super.onCreate(savedInstanceState);window.setBackgroundDrawableResource(android.R.color.black);enableEdgeToEdge();setContent{J1r0xApp(viewModel<AppViewModel>())}}
}
