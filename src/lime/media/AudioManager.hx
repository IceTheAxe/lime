package lime.media;
import haxe.Timer;
import StringTools;
import lime.app.Event;
import lime.system.System;
#if (lime_cffi && !macro && lime_openal)
import lime._internal.backend.native.NativeCFFI;
import lime._internal.backend.native.NativeAudioSource;
import lime._internal.backend.native.NativeVideoSource;
#end
#if (!lime_doc_gen || lime_openal)
import lime.media.openal.AL;
import lime.media.openal.ALC;
import lime.media.openal.ALContext;
import lime.media.openal.ALDevice;
#end
#if (js && html5)
import js.Browser;
#end

#if !lime_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:access(lime._internal.backend.native.NativeCFFI)
@:access(lime.media.openal.ALDevice)
class AudioManager
{
	/**
		The current used context to use for the audio manager.
	**/
	public static var context:AudioContext;
	@:noCompletion public static var __contextGeneration(default, null):Int = 0;
	@:noCompletion public static var __suspended(default, null):Bool = false;
	private static inline var OUTPUT_DEVICE_POLL_TIME:Int = 1000;
	#if (!lime_doc_gen || lime_openal)
	private static var outputDevice:ALDevice;
	#else
	private static var outputDevice:Dynamic;
	#end
	private static var outputDeviceHasDisconnectExt:Bool;
	private static var outputDeviceName:String;
	private static var outputDevicePreferredName:String;
	private static var outputDeviceRecovering:Bool;
	private static var outputDeviceTimer:Timer;

	/**
		Dispatched when the default for the playback device is changed.
		'Device Name' -> Void.
	**/
	public static var onDefaultPlaybackDeviceChanged = new Event<String->Void>();

	/**
		Dispatched whenever a playback device is added.
		'Device Name' -> Void.
	**/
	public static var onPlaybackDeviceAdded = new Event<String->Void>();

	/**
		Dispatched whenever a playback device is removed.
		'Device Name' -> Void.
	**/
	public static var onPlaybackDeviceRemoved = new Event<String->Void>();

	/**
		Dispatched when the default for the capture device is changed.
		'Device Name' -> Void.
	**/
	public static var onDefaultCaptureDeviceChanged = new Event<String->Void>();

	/**
		Dispatched whenever a capture device is added.
		'Device Name' -> Void.
	**/
	public static var onCaptureDeviceAdded = new Event<String->Void>();

	/**
		Dispatched whenever a capture device is removed.
		'Device Name' -> Void.
	**/
	public static var onCaptureDeviceRemoved = new Event<String->Void>();

	/**
		Should it automatically switch to the default playback device whenever it changes.
	**/
	public static var automaticDefaultPlaybackDevice:Bool = true;

	/**
		Mutes the audio manager playback.
	**/
	public static var muted(get, set):Bool;

	/**
		The gain (volume) of the audio manager. A value of `1.0` represents the default volume.
		Property is in a linear scale.
	**/
	public static var gain(get, set):Float;

	@:noCompletion private static var __muted:Bool = false;
	@:noCompletion private static var __gain:Float = 1;
	#if lime_openal
	@:noCompletion private static var __effectExtSupported:Bool;
	@:noCompletion private static var __captureExtSupported:Bool;
	@:noCompletion private static var __disconnectExtSupported:Bool;
	@:noCompletion private static var __deviceClockSupported:Bool;
	@:noCompletion private static var __reopenDeviceSupported:Bool;
	@:noCompletion private static var __systemEventsSupported:Bool;
	@:noCompletion private static var __enumerateAllSupported:Bool;

	@:noCompletion private static var __latencyExtSupported:Bool;
	@:noCompletion private static var __directChannelsExtSupported:Bool;
	@:noCompletion private static var __loopPointsSupported:Bool;
	@:noCompletion private static var __moreFormatsSupported:Bool;
	@:noCompletion private static var __spatializeSupported:Bool;
	@:noCompletion private static var __stereoAnglesSupported:Bool;
	#elseif flash
	@:noCompletion private static var __flashSoundTransform:SoundTransform;
	#end

	/**
		Initializes an `AudioManager` to playback to and capture from audio devices.
		Automatically dispatched when Application is constructed.

		@param	context	Optional; An Audio Context to initalize the `AudioManager` with.
	**/
	public static function init(context:AudioContext = null)
	{
		if (AudioManager.context == null)
		{
			if (context == null)
			{
				AudioManager.context = new AudioContext();
				context = AudioManager.context;

				#if !lime_doc_gen
				if (context.type == OPENAL)
				{
					var alc = context.openal;

					var device = alc.openDevice();
					if (device != null)
					{
						var ctx = alc.createContext(device);
						alc.makeContextCurrent(ctx);
						alc.processContext(ctx);
						__contextGeneration++;
					}
				}
				#end
			}

			AudioManager.context = context;
			setupOutputDeviceRecovery();

			#if (lime_cffi && !macro && lime_openal)
			// Releases the objects that were collected if nothing else gets to them
			var timer = new Timer(100);
			timer.run = function()
			{
				NativeCFFI.lime_al_cleanup();
			};
			#end
		}
	}

	/**
		Refresh the context with optionally to different device.

		Only works on Native target.

		@param	deviceName	Optional; The device name to use to for playbacking the audios.
	**/

    public static function refresh(?deviceName:String):Bool {
        #if (lime_openalsoft && !lime_doc_gen && !macro)
        if(context==null||context.type!=OPENAL)return false;
        var current=ALC.getCurrentContext();if(current==null)return false;
        var device=ALC.getContextsDevice(current);
        if(device!=null && ALC.isExtensionPresent(device,"ALC_SOFT_reopen_device") && ALC.reopenDeviceSOFT(device,deviceName,null)) {__refresh();return true;}
        #end
        return false;
    }


	/**
		Gets the default capture audio device name from the host operating system.

		Only works on Native target.

		@return	The default capture audio device name.
	**/
	public static function getCaptureDefaultDeviceName():String
	{
		#if (lime_openal && !lime_doc_gen)
		if (context != null && context.type == OPENAL && __captureExtSupported)
		{
			return __formatDeviceName(ALC.getString(null, ALC.CAPTURE_DEFAULT_DEVICE_SPECIFIER));
		}
		#end
		return '';
	}

	/**
		Gets all of the available capture audio device names from the host operating system.

		Only works on Native target.

		@return An array containing available capture audio device names.
	**/
	public static function getCaptureDeviceNames():Array<String>
	{
		#if (lime_openal && !lime_doc_gen)
		if (context == null || context.type != OPENAL || !__captureExtSupported) return [];

		final arr = ALC.getStringList(null, ALC.CAPTURE_DEVICE_SPECIFIER);
		for (i in 0...arr.length) arr[i] = __formatDeviceName(arr[i]);

		// A bug with using SDL3 backend to wasapi
		arr.remove("Default Device");

		return arr;
		#else
		return [];
		#end
	}

	/**
		Gets the current used playback audio device name.

		Only works on Native target.

		@return	Current playback audio device name.
	**/
	public static function getCurrentPlaybackDeviceName():String
	{
		#if (lime_openal && !lime_doc_gen)
		if (context != null && context.type == OPENAL)
		{
			var currentContext = ALC.getCurrentContext();
			if (currentContext != null)
			{
				var device = ALC.getContextsDevice(currentContext);
				if (device != null)
				{
					if (__enumerateAllSupported) return __formatDeviceName(ALC.getString(device, ALC.ALL_DEVICES_SPECIFIER));
					else return __formatDeviceName(ALC.getString(device, ALC.DEVICE_SPECIFIER));
				}
			}
		}
		#end
		return '';
	}

	/**
		Gets the default playback audio device name from the host operating system.

		Only works on Native target.

		@return	The default playback audio device name.
	**/
	public static function getPlaybackDefaultDeviceName():String
	{
		#if (lime_openal && !lime_doc_gen)
		if (context != null && context.type == OPENAL)
		{
			if (__enumerateAllSupported) return __formatDeviceName(ALC.getString(null, ALC.DEFAULT_ALL_DEVICES_SPECIFIER));
			else return __formatDeviceName(ALC.getString(null, ALC.DEFAULT_DEVICE_SPECIFIER));
		}
		#end
		return '';
	}

	/**
		Gets all of the available playback audio device names from the host operating system.

		Only works on Native target.

		@return An array containing available playback audio device names.
	**/
	public static function getPlaybackDeviceNames():Array<String>
	{
		#if (lime_openal && !lime_doc_gen)
		if (context == null || context.type != OPENAL) return [];
		else if (!__enumerateAllSupported) return [__formatDeviceName(ALC.getString(null, ALC.DEVICE_SPECIFIER))];

		final arr = ALC.getStringList(null, ALC.ALL_DEVICES_SPECIFIER);
		for (i in 0...arr.length) arr[i] = __formatDeviceName(arr[i]);

		// A bug with using SDL3 backend to wasapi
		arr.remove("Default Device");

		return arr;
		#else
		return [];
		#end
	}

	/**
		Queries the current timer or clock from the current context, best to measure latency, timer drift, etc.

		@return	The current clock time from the current context.
	**/
	public static function getTimer():Float
	{
		#if (lime_openal && !lime_doc_gen)
		if (context != null && context.type == OPENAL && __deviceClockSupported)
		{
			var currentContext = ALC.getCurrentContext();
			if (currentContext != null)
			{
				var device = ALC.getContextsDevice(currentContext);
				if (device != null)
				{
					return ALC.getDoublevSOFT(device, ALC.DEVICE_CLOCK_SOFT)[0] / 1e+6;
				}
			}
		}
		#elseif (js && html5)
		if (context != null && context.type == WEB)
		{
			return context.web.currentTime * 1000.0;
		}
		#end

		return System.getTimer();
	}

	/**
		Queries the current audio device latency.

		Only works on Native target.

		@return	The current audio device latency.
	**/
	public static function getLatency():Float
	{
		#if (lime_openal && !lime_doc_gen)
		if (context != null && context.type == OPENAL && __deviceClockSupported)
		{
			var currentContext = ALC.getCurrentContext();
			if (currentContext != null)
			{
				var device = ALC.getContextsDevice(currentContext);
				if (device != null)
				{
					return ALC.getDoublevSOFT(device, ALC.DEVICE_LATENCY_SOFT)[0] / 1e+6;
				}
			}
		}
		#end

		return 0.0;
	}

	/**
		Resumes the current `AudioManager` context.

		This function does not work on the Flash target.
	**/
	public static function resume():Void
	{
		__suspended = false;

		#if !lime_doc_gen
		if (context != null && context.type == OPENAL)
		{
			var alc = context.openal;
			var currentContext = alc.getCurrentContext();

			if (currentContext != null)
			{
				var device = alc.getContextsDevice(currentContext);
				alc.resumeDevice(device);
				alc.processContext(currentContext);
			}
		}
		#end
	}

	/**
		Shutdowns the current `AudioManager` context.

		This function does not work on the Flash target.
	**/
	public static function shutdown():Void
	{
		#if !lime_doc_gen
		stopOutputDeviceRecovery();

		if (context != null && context.type == OPENAL)
		{
			var alc = context.openal;
			var currentContext = alc.getCurrentContext();

			if (currentContext != null)
			{
				var device = alc.getContextsDevice(currentContext);
				alc.makeContextCurrent(null);
				alc.destroyContext(currentContext);

				if (device != null)
				{
					alc.closeDevice(device);
				}
			}
		}
		#end

		context = null;
	}

	/**
		Pauses the current `AudioManager` context.

		This function does not work on the Flash target.
	**/
	public static function suspend():Void
	{
		// Paused output is not a stall, so videos wait for it instead of playing on
		__suspended = true;

		#if !lime_doc_gen
		if (context != null && context.type == OPENAL)
		{
			var alc = context.openal;
			var currentContext = alc.getCurrentContext();

			if (currentContext != null)
			{
				alc.suspendContext(currentContext);
				var device = alc.getContextsDevice(currentContext);

				if (device != null)
				{
					alc.pauseDevice(device);
				}
			}
		}
		#end
	}

	private static function closeOpenALContext():Void
	{
		#if !lime_doc_gen
		if (context == null || context.type != OPENAL)
		{
			return;
		}

		var alc = context.openal;
		var currentContext = alc.getCurrentContext();

		if (currentContext != null)
		{
			var device = alc.getContextsDevice(currentContext);
			alc.makeContextCurrent(null);
			alc.destroyContext(currentContext);

			if (device != null)
			{
				alc.closeDevice(device);
			}
		}
		#end
	}

	private static function getCurrentOutputDeviceName():String
	{
		#if (lime_cffi && !macro && lime_openal)
		var name = ALC.getString(null, ALC.DEFAULT_ALL_DEVICES_SPECIFIER);

		if (name == null || name.length == 0)
		{
			name = ALC.getString(null, ALC.DEFAULT_DEVICE_SPECIFIER);
		}

		return name;
		#else
		return null;
		#end
	}

	private static function isOutputDeviceConnected():Bool
	{
		#if (lime_cffi && !macro && lime_openal)
		if (outputDevice == null || !outputDeviceHasDisconnectExt)
		{
			return true;
		}

		var connected = ALC.getIntegerv(outputDevice, ALC.CONNECTED, 1);
		return connected == null || connected.length == 0 || connected[0] == ALC.TRUE;
		#else
		return true;
		#end
	}

	private static function openOpenALContext(deviceName:String = null):Bool
	{
		#if !lime_doc_gen
		if (context == null || context.type != OPENAL)
		{
			return false;
		}

		var alc = context.openal;
		var device = alc.openDevice(deviceName);

		if (device == null && deviceName != null)
		{
			device = alc.openDevice();
		}

		if (device == null)
		{
			return false;
		}

		var currentContext = alc.createContext(device);

		if (currentContext == null)
		{
			alc.closeDevice(device);
			return false;
		}

		alc.makeContextCurrent(currentContext);
		alc.processContext(currentContext);
		__contextGeneration++;
		return true;
		#else
		return false;
		#end
	}

	private static function recoverOutputDevice(deviceName:String = null):Void
	{
		#if (lime_cffi && !macro && lime_openal)
		if (outputDeviceRecovering || context == null || context.type != OPENAL)
		{
			return;
		}

		outputDeviceRecovering = true;
		NativeAudioSource.prepareAudioContextRecovery();
		NativeVideoSource.prepareAudioContextRecovery();
		closeOpenALContext();

		if (openOpenALContext(deviceName))
		{
			refreshOutputDeviceRecovery();
			NativeAudioSource.restoreAudioContextRecovery();
			NativeVideoSource.restoreAudioContextRecovery();

			// The new device starts playing, so it is paused until resume() as the old one was
			if (__suspended)
			{
				suspend();
			}
		}

		outputDeviceRecovering = false;
		#end
	}

	private static function refreshOutputDeviceRecovery():Void
	{
		#if (lime_cffi && !macro && lime_openalsoft)
		if (context == null || context.type != OPENAL)
		{
			outputDevice = null;
			outputDeviceHasDisconnectExt = false;
			outputDeviceName = null;
			return;
		}

		var alc = context.openal;
		var currentContext = alc.getCurrentContext();
		outputDevice = currentContext != null ? alc.getContextsDevice(currentContext) : null;
		outputDeviceHasDisconnectExt = outputDevice != null && ALC.isExtensionPresent(outputDevice, "ALC_EXT_disconnect");
		outputDeviceName = getCurrentOutputDeviceName();
		#end
	}

	private static function setupOutputDeviceRecovery():Void
	{
		// Only OpenAL Soft reports ALC_EXT_disconnect to Lime, so the system OpenAL on iOS and tvOS,
		// MojoAL and Emscripten have no way to notice a lost device
		#if (lime_cffi && !macro && lime_openalsoft)
		stopOutputDeviceRecovery();

		if (context == null || context.type != OPENAL)
		{
			return;
		}

		refreshOutputDeviceRecovery();

		if (!outputDeviceHasDisconnectExt)
		{
			return;
		}

		outputDevicePreferredName = outputDeviceName;
		// ALC_EXT_disconnect exposes disconnect state, but not device-change events.
		// Polling is kept as the compatibility fallback for that older API.
		outputDeviceTimer = new Timer(OUTPUT_DEVICE_POLL_TIME);
		outputDeviceTimer.run = updateOutputDeviceRecovery;
		#end
	}

	private static function stopOutputDeviceRecovery():Void
	{
		if (outputDeviceTimer != null)
		{
			outputDeviceTimer.stop();
			outputDeviceTimer = null;
		}

		outputDevice = null;
		outputDeviceHasDisconnectExt = false;
		outputDeviceName = null;
		outputDevicePreferredName = null;
		outputDeviceRecovering = false;
	}

	private static function updateOutputDeviceRecovery():Void
	{
		#if (lime_cffi && !macro && lime_openal)
		if (outputDeviceRecovering || context == null || context.type != OPENAL)
		{
			return;
		}

		if (!isOutputDeviceConnected())
		{
			recoverOutputDevice();
			return;
		}

		if (outputDevicePreferredName != null && outputDeviceName != outputDevicePreferredName)
		{
			var currentName = getCurrentOutputDeviceName();

			if (currentName == outputDevicePreferredName)
			{
				recoverOutputDevice(outputDevicePreferredName);
				return;
			}

			outputDeviceName = currentName;
		}
		#end
	}

	@:noCompletion private static function __refresh():Void
	{
		if (context == null || context.type != OPENAL) return;

		var currentContext = ALC.getCurrentContext();
		if (currentContext == null) return;

		var device = ALC.getContextsDevice(currentContext);
		if (device == null) return;

		__effectExtSupported = ALC.isExtensionPresent(null, "ALC_EXT_EFX");
		__captureExtSupported = ALC.isExtensionPresent(null, 'ALC_EXT_CAPTURE');
		__disconnectExtSupported = ALC.isExtensionPresent(null, 'ALC_EXT_disconnect');
		__deviceClockSupported = ALC.isExtensionPresent(null, 'ALC_SOFT_device_clock');
		__reopenDeviceSupported = ALC.isExtensionPresent(null, 'ALC_SOFT_reopen_device');
		__systemEventsSupported = ALC.isExtensionPresent(null, 'ALC_SOFT_system_events');
		__enumerateAllSupported = ALC.isExtensionPresent(null, 'ALC_ENUMERATE_ALL_EXT');

		__latencyExtSupported = AL.isExtensionPresent('AL_SOFT_source_latency');
		__directChannelsExtSupported = AL.isExtensionPresent('AL_SOFT_direct_channels') && AL.isExtensionPresent('AL_SOFT_direct_channels_remix');
		__loopPointsSupported = AL.isExtensionPresent('AL_SOFT_loop_points');
		__moreFormatsSupported = AL.isExtensionPresent('AL_EXT_MCFORMATS');
		__spatializeSupported = AL.isExtensionPresent('AL_SOFT_source_spatialize');
		__stereoAnglesSupported = AL.isExtensionPresent('AL_EXT_STEREO_ANGLES');

		gain = __gain;
		AL.distanceModel(AL.NONE);
	}

	@:noCompletion private static inline function get_muted():Bool
	{
		return __muted;
	}

	@:noCompletion private static inline function set_muted(value:Bool):Bool
	{
		__muted = value;
		if (context == null) return __muted;

		#if !lime_doc_gen
		#if lime_openal
		if (context.type == OPENAL) AL.listenerf(AL.GAIN, value ? 0 : __gain);
		#end
		#end

		return __muted;
	}

	@:noCompletion private static inline function get_gain():Float
	{
		return __gain;
	}

	@:noCompletion private static inline function set_gain(value:Float):Float
	{
		__gain = value;
		if (context == null) return __gain;

		#if !lime_doc_gen
		#if lime_openal
		if (context.type == OPENAL) AL.listenerf(AL.GAIN, __muted ? 0 : value);
		#end
		#end

		return __gain;
	}

	@:noCompletion private static function __formatDeviceName(deviceName:String)
	{
		if (StringTools.startsWith(deviceName, 'OpenAL Soft on ')) return deviceName.substr(15);
		else if (StringTools.startsWith(deviceName, 'OpenAL on ')) return deviceName.substr(10);
		else if (StringTools.startsWith(deviceName, 'Generic Software on ')) return deviceName.substr(20);
		else return deviceName;
	}
}
