-- The state of a fresh VST3 instance of each DMGAudio plugin, as the plugin writes it
-- (REAPER 7.82, macOS): the base a preset is laid over. Plugin defaults, not presets.
return {
  Multiplicity = [==[
{
	"presets":	[{
			"parameters":	"default",
			"name":	"None"
		}],
	"ab":	[{
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}],
	"settings":	{
		"uimode":	0,
		"currentAB":	0,
		"lastAB":	1,
		"lastListen":	2,
		"linkPage":	0,
		"zoomState":	0,
		"freeWidth":	844,
		"currentBand":	0,
		"bandGraph":	1,
		"meterChannel":	2,
		"meterShow":	2,
		"meterZoom":	0,
		"meterRange":	24,
		"lastPreset":	0,
		"lastPresetFolder":	"",
		"parameterLocks":	[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		"parameterLinks":	[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	},
	"uiprefs":	{
		"Graph":	{
			"Range":	{
				"value":	4,
				"values":	["3dB", "6dB", "12dB", "18dB", "24dB", "36dB"]
			},
			"Readout":	{
				"value":	0,
				"values":	["Off", "Analyser", "Graph", "Both"]
			},
			"Readout Position":	{
				"value":	0,
				"values":	["Top", "Bottom"]
			},
			"GR Decay":	{
				"value":	100,
				"unit":	"%",
				"min":	0,
				"max":	100
			},
			"Highlight Current Band":	{
				"value":	1,
				"values":	["Off", "On"]
			},
			"Draw Style":	{
				"value":	2,
				"values":	["Filled", "Outlined", "Both"]
			},
			"Inverted Q":	{
				"value":	0,
				"values":	["Off", "On"]
			},
			"Background":	{
				"value":	0,
				"values":	["Dim", "Med", "Bright"]
			},
			"Gradient":	{
				"value":	1,
				"values":	["Off", "On"]
			}
		},
		"Analyser":	{
			"Decay":	{
				"value":	2,
				"values":	["Instant", "Fast", "Med", "Slow"]
			},
			"Range":	{
				"value":	0,
				"values":	["96dB", "80dB", "64dB", "48dB"]
			},
			"Top":	{
				"value":	0,
				"values":	["0dB", "-12dB", "-24dB", "-36dB"]
			},
			"Tilt":	{
				"value":	0,
				"values":	["0dB", "3dB", "4.5dB", "6dB"]
			},
			"Smoothing":	{
				"value":	0,
				"values":	["None", "Mild", "Med", "Heavy"]
			},
			"Display":	{
				"value":	0,
				"values":	["Filled", "Outlined", "Off"]
			}
		},
		"Release":	{
			"Flash Labels":	{
				"value":	0,
				"values":	["Off", "On"]
			}
		}
	},
	"v101":	true
}
]==],
  Expurgate = [==[
{
	"presets":	[{
			"parameters":	"default",
			"name":	"None"
		}],
	"ab":	[{
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}],
	"settings":	{
		"uimode":	0,
		"currentAB":	0,
		"lastAB":	1,
		"lastListen":	2,
		"linkPage":	0,
		"zoomState":	0,
		"freeWidth":	728,
		"lastPreset":	0,
		"lastPresetFolder":	""
	},
	"uiprefs":	{
		"Graph":	{
			"Readout":	{
				"value":	0,
				"values":	["Off", "Analyser", "Graph", "Both"]
			}
		},
		"Analyser":	{
			"Decay":	{
				"value":	2,
				"values":	["Instant", "Fast", "Med", "Slow"]
			},
			"Range":	{
				"value":	0,
				"values":	["96dB", "80dB", "64dB", "48dB"]
			},
			"Top":	{
				"value":	0,
				"values":	["0dB", "-12dB", "-24dB", "-36dB"]
			},
			"Display":	{
				"value":	0,
				"values":	["Filled", "Outlined", "Both", "Off"]
			}
		}
	}
}
]==],
  Essence = [==[
{
	"presets":	[{
			"parameters":	{
				"kThreshold":	0.4166670144,
				"kRatio":	0.5090817213,
				"kAttack":	0.3743887544,
				"kSplitBPF":	0,
				"kSplitBPFFreq":	0.5664925575,
				"kSplitBPFQ":	0,
				"kSplitHPFSlope":	0.1604278088,
				"kSplitType":	0.7142857313,
				"kSCHPF":	1,
				"kSCHPFFreq":	0.7696467042,
				"kSCPeak":	1,
				"kSCPeakGain":	0.7121067643,
				"kSCPeakFreq":	0.8350619078,
				"kSCPeakQ":	0.5338756442,
				"kSCLPFFreq":	0.6202536821,
				"kSCSource":	0,
				"kLookahead":	0,
				"kLinearPhase":	0,
				"kNoiseDetector":	0.5000000000
			},
			"name":	"02 - TL Start Deess"
		}],
	"ab":	[{
			"parameters":	{
				"kThreshold":	0.4166670144,
				"kRatio":	0.5090817213,
				"kAttack":	0.3743887544,
				"kSplitBPF":	0,
				"kSplitBPFFreq":	0.5664925575,
				"kSplitBPFQ":	0,
				"kSplitHPFSlope":	0.1604278088,
				"kSplitType":	0.7142857313,
				"kSCHPF":	1,
				"kSCHPFFreq":	0.7696467042,
				"kSCPeak":	1,
				"kSCPeakGain":	0.7121067643,
				"kSCPeakFreq":	0.8350619078,
				"kSCPeakQ":	0.5338756442,
				"kSCLPFFreq":	0.6202536821,
				"kSCSource":	0,
				"kLookahead":	0,
				"kLinearPhase":	0,
				"kNoiseDetector":	0.5000000000
			}
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}, {
			"parameters":	"default"
		}],
	"settings":	{
		"uimode":	0,
		"currentAB":	0,
		"lastAB":	1,
		"lastListen":	1,
		"linkPage":	0,
		"zoomState":	0,
		"freeWidth":	1143,
		"lastPreset":	2,
		"lastPresetFolder":	"/Library/Application Support/DMGAudio/Essence/Presets/"
	},
	"uiprefs":	{
		"Graph":	{
			"Readout":	{
				"value":	0,
				"values":	["Off", "Analyser", "Graph", "Both"]
			},
			"Autolisten":	{
				"value":	0,
				"values":	["Split", "Pass", "Difference"]
			}
		},
		"Analyser":	{
			"Decay":	{
				"value":	2,
				"values":	["Instant", "Fast", "Med", "Slow"]
			},
			"Range":	{
				"value":	0,
				"values":	["96dB", "80dB", "64dB", "48dB"]
			},
			"Top":	{
				"value":	0,
				"values":	["0dB", "-12dB", "-24dB", "-36dB"]
			},
			"Display":	{
				"value":	0,
				"values":	["Filled", "Outlined", "Both", "Off"]
			}
		}
	}
}
]==],
}
