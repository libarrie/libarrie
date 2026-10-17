package app.libarrie.android

import android.app.Application

class LibarrieApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        app.libarrie.android.data.WorkManagerTransfers.schedule(this)
    }
}
