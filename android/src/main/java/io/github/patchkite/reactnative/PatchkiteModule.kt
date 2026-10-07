package io.github.patchkite.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import org.json.JSONObject
import java.util.concurrent.Executors

class PatchkiteModule(reactContext: ReactApplicationContext) : NativePatchkiteSpec(reactContext) {
  companion object {
    const val NAME = "Patchkite"
    private val executor = Executors.newSingleThreadExecutor()
  }

  private val core get() = PatchkiteCore.get(reactApplicationContext)

  override fun getName() = NAME

  private fun async(promise: Promise, block: () -> Any?) {
    executor.execute {
      try {
        promise.resolve(block())
      } catch (e: Exception) {
        PatchkiteUtils.log("Error: ${e.message}")
        promise.reject("PATCHKITE_ERROR", e.message, e)
      }
    }
  }

  private fun JSONObject.toWritableMap(): WritableMap {
    val map = Arguments.createMap()
    for (key in keys()) {
      when (val v = get(key)) {
        is Boolean -> map.putBoolean(key, v)
        is Int -> map.putInt(key, v)
        is Long -> map.putDouble(key, v.toDouble())
        is Double -> map.putDouble(key, v)
        is String -> map.putString(key, v)
        JSONObject.NULL -> map.putNull(key)
        else -> map.putString(key, v.toString())
      }
    }
    return map
  }

  override fun getConfiguration(promise: Promise) = async(promise) {
    Arguments.createMap().apply {
      putString("appVersion", core.appVersion)
      putString("deploymentKey", core.deploymentKey)
      putString("serverUrl", core.serverUrl)
      putString("clientUniqueId", core.clientUniqueId)
      putString("publicKey", core.publicKey)
      putString("binaryHash", core.binaryBundleHash)
    }
  }

  override fun getUpdateMetadata(updateState: Double, promise: Promise) = async(promise) {
    core.getUpdateMetadata(updateState.toInt())?.toWritableMap()
  }

  override fun downloadUpdate(updatePackage: ReadableMap, promise: Promise) = async(promise) {
    val pkg = JSONObject(updatePackage.toHashMap())
    core.downloadUpdate(pkg) { received, total ->
      emitOnDownloadProgress(
        Arguments.createMap().apply {
          putDouble("receivedBytes", received.toDouble())
          putDouble("totalBytes", total.toDouble())
        }
      )
    }.toWritableMap()
  }

  override fun installUpdate(packageHash: String, installMode: Double, promise: Promise) = async(promise) {
    core.installUpdate(packageHash)
    null
  }

  override fun isFailedUpdate(packageHash: String, promise: Promise) = async(promise) { core.isFailedUpdate(packageHash) }

  override fun isFirstRun(packageHash: String, promise: Promise) = async(promise) { core.isFirstRun(packageHash) }

  override fun notifyApplicationReady(promise: Promise) = async(promise) {
    core.notifyApplicationReady()
    null
  }

  override fun popRollbackReport(promise: Promise) = async(promise) { core.popRollbackReport()?.toWritableMap() }

  override fun getValue(key: String, promise: Promise) = async(promise) { core.getValue(key) }

  override fun setValue(key: String, value: String, promise: Promise) = async(promise) {
    core.setValue(key, value)
    null
  }

  override fun restartApp() {
    Patchkite.restart(reactApplicationContext)
  }

  override fun clearUpdates() {
    core.clearUpdates()
  }
}
