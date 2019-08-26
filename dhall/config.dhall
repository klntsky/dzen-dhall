let prelude = ./prelude/package.dhall
let types = ./types/package.dhall
let utils = ./utils/package.dhall

-- * Types

let AbsolutePosition = types.AbsolutePosition
let Address = types.Address
let Assertion = types.Assertion
let Bar = types.Bar
let Button = types.Button
let Carrier = types.Carrier
let Check = types.Check
let Color = types.Color
let Configuration = types.Configuration
let Direction = types.Direction
let Event = types.Event
let Fade = types.Fade
let Hook = types.Hook
let Image = types.Image
let Marquee = types.Marquee
let Padding = types.Padding
let Plugin = types.Plugin
let Position = types.Position
let Settings = types.Settings
let Shell = types.Shell
let Slider = types.Slider
let Source = types.Source
let State = types.State
let StateMap = types.StateMap
let Transition = types.Transition
let Variable = types.Variable
let VerticalDirection = types.VerticalDirection

-- * Utility functions

let mkAddress : Text → Address = utils.mkAddress
let mkEvent : Text → Event = utils.mkEvent
let mkState : Text → State = utils.mkState
let mkVariable : Text → Variable = utils.mkVariable

let showAddress : Address → Text = utils.showAddress
let showEvent : Event → Text = utils.showEvent
let showState : State → Text = utils.showState
let showVariable : Variable → Text = utils.showVariable

let mkBashHook : Shell → Hook = utils.mkBashHook
let addHook : Hook → Transition → Transition = utils.addHook

let mkFade : VerticalDirection → Natural → Natural → Fade = utils.mkFade
let mkSlider : Fade → Fade → Natural → Slider = utils.mkSlider
let mkMarquee : Natural → Natural → Bool → Marquee = utils.mkMarquee

let mkTransition : Event → State → State → Transition = utils.mkTransition
let mkTransitions : Event → List State → State → Transition = utils.mkTransitions

let emit : Event → Shell = utils.emit
let get : Variable → Shell = utils.get
let getEvent : Shell = utils.getEvent
let getCurrentState : Shell = utils.getCurrentState
let getNextState : Shell = utils.getNextState
let query : Address → Shell = utils.query
let set : Variable → Shell → Shell = utils.set

let defaults = utils.defaults

let bar
	: Bar
	=   λ(Bar : Type)
	  → λ(cr : Carrier Bar)
	  → -- Text primitives:
		let text : Text → Bar = cr.text
		let markup : Text → Bar = cr.markup

		-- Combining multiple `Bar`s into one:
		let join : List Bar → Bar = cr.join

		-- Primitives of Dzen markup language:
		let fg : Color → Bar → Bar = cr.fg
		let bg : Color → Bar → Bar = cr.bg
		let i : Image → Bar = cr.i
		let r : Natural → Natural → Bar = cr.r
		let ro : Natural → Natural → Bar = cr.ro
		let c : Natural → Bar = cr.c
		let co : Natural → Bar = cr.co
		let p : Position → Bar → Bar = cr.p
		let pa : AbsolutePosition → Bar → Bar = cr.pa
		let ca : Button → Shell → Bar → Bar = cr.ca
		let ib : Bar → Bar = cr.ib

		-- Animations:
		let slider : Slider → List Bar → Bar = cr.slider
		let marquee : Marquee → Bar → Bar = cr.marquee

		-- Other:
		let pad : Natural → Padding → Bar → Bar = cr.pad
		let trim : Natural → Direction → Bar → Bar = cr.trim
		let source : Source → Bar = cr.source
		let plug : Plugin → Bar = cr.plug
		let automaton
			: Address → List Transition → StateMap Bar → Bar
			= cr.automaton
		let check : Text → Assertion → Bar = cr.check
		let scope : Bar → Bar = cr.scope
		let define : Variable → Text → Bar = cr.define

		-- Utilities:
		let bash : Natural → Shell → Bar = utils.mkBash Bar cr
		let bashWithBinaries
			: List Text → Natural → Shell → Bar
			= utils.mkBashWithBinaries Bar cr
		let reader : Variable → Natural → Bar = utils.mkReader Bar cr
		let separateBy : Bar → List Bar → Bar = utils.mkSeparateBy Bar cr
		let separate : List Bar → Bar = separateBy (text " | ")

		-- Pre-defined bars
		let memoryUsage
			: Bar
			= bashWithBinaries
			  [ "free", "grep", "awk" ]
			  5000
			  ''
			  free -b | grep Mem | awk '{ printf("%.0f\n", $3 * 100 / $2) }';
			  ''

		let swapUsage
			: Bar
			= bashWithBinaries
			  [ "free", "grep", "awk" ]
			  5000
			  ''
			  free -b | grep Swap | awk '{ printf("%.0f\n", $3 * 100 / $2) }';
			  ''

		let date
			: Bar
			= bashWithBinaries [ "date" ] 1000 "date +'%d.%m.%Y'"

		let time
			: Bar
			= bashWithBinaries [ "date" ] 1000 "date +'%H:%M'"

		let accent : Bar → Bar = fg "white"

		in    -- Your bar definition starts below.

			  separate
			  [ join [ text "Mem: ", accent memoryUsage, text "%" ]
			  , join [ text "Swap: ", accent swapUsage, text "%" ]
			  , join [ date, text " ", accent time ]

			  -- You can add new plugins right here.

			  ]
			: Bar

in  utils.mkConfigs [ { bar = bar, settings = defaults.settings } ] : List Configuration
