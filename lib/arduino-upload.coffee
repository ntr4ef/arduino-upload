{CompositeDisposable} = require 'atom'
{spawn} = require 'child_process'
String::strip = -> if String::trim? then @trim() else @replace /^\s+|\s+$/g, ""

fs = require 'fs'
path = require 'path'
OutputView = require './output-view'
serialport = require 'serialport'

output = null
serial = null
serialeditor = null

removeDir = (dir) ->
	if fs.existsSync dir
		for file in fs.readdirSync dir
			path = dir + '/' + file
			if fs.lstatSync(path).isDirectory()
				removeDir path
			else
				fs.unlinkSync path
			
		fs.rmdirSync dir
module.exports = ArduinoUpload =
	config:
		arduinoExecutablePath:
			type: 'string'
			default: 'arduino'
		baudRate:
			type: 'number'
			default: '9600'
		board:
			type: 'string'
			default: ''

	activate: (state) ->
		# Setup to use the new composite disposables API for registering commands
		@subscriptions = new CompositeDisposable
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:verify': => @build(false)
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:build': => @build(true)
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:upload': => @upload()
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:serial-monitor': => @openserial()
		
		output = new OutputView
		atom.workspace.addBottomPanel(item:output)
		output.hide()



	deactivate: ->
		@subscriptions.dispose()
		output?.remove()
		@closeserial()

	build: (keep) ->
		editor = atom.workspace.getActivePaneItem()
		file = editor?.buffer?.file?.getPath()?.split "/"
		file?.pop()
		name = file?.pop()
		file?.push name
		workpath = file?.join '/'
		name += '.ino'
		file?.push name
		file = file?.join '/'
		dispError = false
		output.reset()
		if fs.existsSync file
			options = [file,'--verify']
			if atom.config.get('arduino-upload.board') != ''
				options.push '--board'
				options.push atom.config.get('arduino-upload.board')
			if keep
				options.push '-v'
				options.push '--preserve-temp-files'
			stdoutput = spawn atom.config.get('arduino-upload.arduinoExecutablePath'), options
			buildpath = ''
			stdoutput.stdout.on 'data', (data) ->
				if keep
					s = data.toString().replace ///.*"([\/\w\-:\.]+)#{name}\.eep".*///, '$1'
					if s && s!=data.toString()
						buildpath = s
				
				if data.toString().strip().indexOf('Sketch') == 0 || data.toString().strip().indexOf('Global') == 0
					atom.notifications.addInfo data.toString()
			
			stdoutput.stderr.on 'data', (data) ->
				if data.toString().strip() == "exit status 1"
					dispError = false
				if dispError
					output.addLine data.toString(), workpath
				if data.toString().strip() == "Verifying..."
					dispError = true
			stdoutput.on 'close', (code) ->
				if code != 0
					atom.notifications.addError 'Build failed'
				else if keep && buildpath!=''
					buildpath = buildpath.strip()
					
					for ending in ['.eep','.elf','.hex']
						console.log buildpath+name+ending
						fs.createReadStream(buildpath+name+ending).pipe(fs.createWriteStream(workpath+'/'+name+ending))
					removeDir(buildpath)
					
				output.finish()
		else
			atom.notifications.addError "File isn't part of an Arduino sketch!"
	upload: ->
		editor = atom.workspace.getActivePaneItem()
		file = editor?.buffer?.file?.getPath()?.split "/"
		file?.pop()
		name = file?.pop()
		file?.push name
		workpath = file?.join '/'
		file?.push name+".ino"
		file = file?.join "/"
		dispError = false
		uploading = false
		output.reset()
		if fs.existsSync(file)
			@getPort (port) =>
				if port == ''
					atom.notifications.addError 'No arduino connected'
					return
				options = [file,'-v','--upload','--port',port]
				if atom.config.get('arduino-upload.board') != ''
					options.push '--board'
					options.push atom.config.get('arduino-upload.board')
				stdoutput = spawn atom.config.get('arduino-upload.arduinoExecutablePath'), options
				
				stdoutput.stdout.on 'data', (data) ->
					if data.toString().strip().indexOf('Sketch') == 0 || data.toString().strip().indexOf('Global') == 0
						atom.notifications.addInfo data.toString()
				
				stdoutput.stderr.on 'data', (data) ->
					if data.toString().strip().indexOf("avrdude:") == 0 && !uploading
						uploading = true
						atom.notifications.addInfo 'Uploading sketch...'
					else if dispError && !uploading
						output.addLine data.toString(), workpath
					else if data.toString().strip() == "Verifying and uploading..."
						dispError = true
				
				stdoutput.on 'close', (code) ->
					output.finish()
					if code == 0
						atom.notifications.addInfo 'Successfully uploaded sketch'
					else
						if uploading
							atom.notifications.addError "Couldn't upload to board, is it connected?"
						else
							atom.notifications.addError 'Build failed'
		else
			atom.notifications.addError "File isn't part of an Arduino sketch!"
	isArduino: (port) ->
		if port.manufacturer == 'FTDI'
			return true
		if port.vendorId == '0x0403' || port.vendorId == '0x2341'
			return true
		return false
	getPort: (callback) ->
		p = ''
		serialport.list (err,ports) =>
			for port in ports
				if @isArduino(port)
					p = port.comName
					break
			callback p
	openserialport: ->
		if serial!=null
			atom.notifications.addInfo 'wut, serial open?'
			return
		p = ''
		@getPort (port) =>
			if port == ''
				atom.notifications.addError 'No Arduino found!'
				@closeserial()
				return
			
			serial = new serialport.SerialPort port, {
					baudRate: atom.config.get('arduino-upload.baudRate')
					parser: serialport.parsers.readline "\n"
				}
			
			serial.on 'open', (data) =>
				atom.notifications.addInfo 'new serial connection'
			serial.on 'data', (data) =>
				serialeditor?.insertText data
			serial.on 'close', (data) =>
				@closeserial()
				atom.notifications.addInfo 'Serial connection closed'
			serial.on 'error', (data) =>
				@closeserial()
				atom.notifications.addInfo 'error in serial connection'
	openserial: ->
		if serial!=null
			return
		
		atom.workspace.open('Serial Monitor').then (editor) =>
			editor.setText ''
			
			editor.onDidDestroy =>
				@closeserial()
			serialeditor = editor
			@openserialport()
	closeserial: ->
		serial?.close (err) ->
			return
		serial = null
		
		serialeditor?.destroy()
		serialeditor = null
