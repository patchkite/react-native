package io.github.patchkite.reactnative

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.facebook.react.ReactApplication
import com.facebook.react.bridge.JSBundleLoader
import kotlin.system.exitProcess

/**
 * Public entry point.
 *
 * ```kotlin
 * getDefaultReactHost(
 *   context = applicationContext,
 *   packageList = PackageList(this).packages,
 *   jsBundleFilePath = Patchkite.getJSBundleFile(applicationContext),
 * )
 * ```
 */
object Patchkite {
  /** Path of the latest update bundle, or null to use the bundle shipped in the APK. */
  @JvmStatic
  @JvmOverloads
  fun getJSBundleFile(context: Context, assetsBundleFileName: String = PatchkiteCore.DEFAULT_BUNDLE_NAME): String? {
    val core = PatchkiteCore.get(context)
    core.bundleFileName = assetsBundleFileName
    val path = core.resolveBundlePath()
    PatchkiteUtils.log(if (path != null) "Running update: $path" else "Running the bundle shipped in the binary.")
    return path
  }

  /** Override the deployment key/server URL programmatically (optional). */
  @JvmStatic
  fun configure(context: Context, deploymentKey: String? = null, serverUrl: String? = null) {
    val core = PatchkiteCore.get(context)
    deploymentKey?.let { core.deploymentKey = it }
    serverUrl?.let { core.serverUrl = it }
  }

  /** Reloads JS with the latest bundle (bridgeless/new architecture). */
  internal fun restart(context: Context) {
    val core = PatchkiteCore.get(context)
    val path = core.resolveBundlePath()
    Handler(Looper.getMainLooper()).post {
      try {
        val host = (context.applicationContext as ReactApplication).reactHost ?: throw IllegalStateException("ReactHost null")
        val loader =
          if (path != null) JSBundleLoader.createFileLoader(path)
          else JSBundleLoader.createAssetLoader(context, "assets://${core.bundleFileName}", true)
        val delegateField = host.javaClass.getDeclaredField("reactHostDelegate").apply { isAccessible = true }
        val delegate = delegateField.get(host)
        val loaderField = findField(delegate.javaClass, "jsBundleLoader").apply { isAccessible = true }
        loaderField.set(delegate, loader)
        host.reload("Patchkite: update installed")
      } catch (e: Exception) {
        PatchkiteUtils.log("In-process reload failed (${e.message}), restarting the process.")
        restartProcess(context)
      }
    }
  }

  private fun findField(cls: Class<*>, name: String): java.lang.reflect.Field {
    var c: Class<*>? = cls
    while (c != null) {
      try {
        return c.getDeclaredField(name)
      } catch (_: NoSuchFieldException) {
        c = c.superclass
      }
    }
    throw NoSuchFieldException(name)
  }

  private fun restartProcess(context: Context) {
    val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
    context.startActivity(intent)
    exitProcess(0)
  }
}
