require 'nokogiri'

module SippyCup
  class Scenario
    VALID_DTMF = %w{0 1 2 3 4 5 6 7 8 9 0 * # A B C D}.freeze
    MSEC = 1_000

    def initialize(name, args = {}, &block)
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.scenario name: name
      end

      parse_args args

      @filename = name.downcase.gsub(/\W+/, '_')
      @doc = builder.doc
      @media = Media.new @from_addr, @from_port, @to_addr, @to_port
      @scenario = @doc.xpath('//scenario').first

      instance_eval &block
    end

    def parse_args(args)
      raise ArgumentError, "Must include source IP:PORT" unless args.keys.include? :source
      raise ArgumentError, "Must include destination IP:PORT" unless args.keys.include? :destination

      @from_addr, @from_port = args[:source].split ':'
      @to_addr, @to_port = args[:destination].split ':'
      @from_user = args[:from_user] || "sipp"
    end

    def compile_media
      @media.compile!
    end

    def sleep(seconds)
      # TODO play silent audio files to the server to fill the gap
      pause seconds * MSEC
      @media << "silence:#{seconds * MSEC}"
    end

    def invite(opts = {})
      opts[:retrans] ||= 500
      # FIXME: The DTMF mapping (101) is hard-coded. It would be better if we could
      # get this from the DTMF payload generator
      msg = <<-INVITE

        INVITE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
        Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
        From: sipp <sip:#{@from_user}@[local_ip]>;tag=[call_number]
        To: <sip:[service]@[remote_ip]:[remote_port]>
        Call-ID: [call_id]
        CSeq: [cseq] INVITE
        Contact: sip:#{@from_user}@[local_ip]:[local_port]
        Max-Forwards: 100
        Content-Type: application/sdp
        Content-Length: [len]
  
        v=0
        o=user1 53655765 2353687637 IN IP[local_ip_type] [local_ip]
        s=-
        c=IN IP[media_ip_type] [media_ip]
        t=0 0
        m=audio [media_port] RTP/AVP 0 101
        a=rtpmap:0 PCMU/8000
        a=rtpmap:101 telephone-event/8000
        a=fmtp:101 0-15
      INVITE
      send = new_send msg, opts
      @scenario << send
    end

    def receive_trying(opts = {})
      opts[:optional] ||= true
      opts.merge! response: 100
      @scenario << new_recv(opts)
    end
    alias :receive_100 :receive_trying
      
    def receive_ringing(opts = {})
      opts[:optional] ||= true
      opts.merge! response: 180
      @scenario << new_recv(opts)
    end
    alias :receive_180 :receive_ringing
      
    def receive_progress(opts = {})
      opts[:optional] ||= true
      opts.merge! response: 183
      @scenario << new_recv(opts)
    end
    alias :receive_183 :receive_progress

    def receive_answer(opts = {})
      opts[:optional] ||= false
      opts.merge! response: 200
      recv = new_recv opts
      # Record Record Set: Make the Route headers available via [route] later
      recv['rrs'] = true
      @scenario << recv
    end
    alias :receive_200 :receive_answer

    def ack_answer(opts = {})
      msg = <<-ACK

        ACK [next_url] SIP/2.0
        Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
        From: <sip:#{@from_user}@[local_ip]>;tag=[call_number]
        [last_To:]
        [routes]
        Call-ID: [call_id]
        CSeq: [cseq] ACK
        Contact: sip:#{@from_user}@[local_ip]:[local_port]
        Max-Forwards: 100
        Content-Length: 0
      ACK
      @scenario << new_send(msg, opts)
      start_media
    end

    def start_media
      nop = Nokogiri::XML::Node.new 'nop', @doc
      action = Nokogiri::XML::Node.new 'action', @doc
      nop << action
      exec = Nokogiri::XML::Node.new 'exec', @doc
      exec['play_pcap_audio'] = "#{@filename}.pcap"
      action << exec
      @scenario << nop
    end

    ##
    # Send DTMF digits
    # @param[String] DTMF digits to send. Must be 0-9, *, # or A-D
    def send_digits(digits, delay = 0.250)
      delay = 0.250 * MSEC # FIXME: Need to pass this down to the media layer
      digits.split('').each do |digit|
        raise ArgumentError, "Invalid DTMF digit requested: #{digit}" unless VALID_DTMF.include? digit

        @media << "dtmf:#{digit}"
        @media << "silence:#{delay}"
        pause delay * 2
      end
    end

    def send_bye(opts = {})
      msg = <<-MSG

        BYE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
        [last_Via:]
        [last_From:]
        [last_To:]
        [last_Call-ID]
        CSeq: [cseq] BYE
        Contact: <sip:[local_ip]:[local_port];transport=[transport]>
        Max-Forwards: 100
        Content-Length: 0
      MSG
      @scenario << new_send(msg, opts)
    end

    def receive_bye(opts = {})
      opts.merge! request: 'BYE'
      @scenario << new_recv(opts)
    end

    def ack_bye(opts = {})
      msg = <<-ACK

        SIP/2.0 200 OK
        [last_Via:]
        [last_From:]
        [last_To:]
        [routes]
        [last_Call-ID:]
        [last_CSeq:]
        Contact: <sip:[local_ip]:[local_port];transport=[transport]>
        Max-Forwards: 100
        Content-Length: 0
      ACK
      @scenario << new_send(msg, opts)
    end

    def to_xml
      @doc.to_xml
    end

    def compile!
      xml_file = File.open "#{@filename}.xml", 'w' do |file|
        file.write @doc.to_xml
      end
      compile_media.to_file filename: "#{@filename}.pcap"
    end

  private
    def pause(msec)
      pause = Nokogiri::XML::Node.new 'pause', @doc
      pause['milliseconds'] = msec.to_i
      @scenario << pause
    end

    def new_send(msg, opts = {})
      send = Nokogiri::XML::Node.new 'send', @doc
      opts.each do |k,v|
        send[k.to_s] = v
      end
      send << "\n"
      send << Nokogiri::XML::CDATA.new(@doc, msg)
      send << "\n" #Newlines are required before and after CDATA so SIPp will parse properly
      send
    end

    def new_recv(opts = {})
      raise ArgumentError, "Receive must include either a response or a request" unless opts.keys.include?(:response) || opts.keys.include?(:request)
      recv = Nokogiri::XML::Node.new 'recv', @doc
      recv['request']  = opts.delete :request  if opts.keys.include? :request
      recv['response'] = opts.delete :response if opts.keys.include? :response
      recv['optional'] = !!opts.delete(:optional)
      opts.each do |k,v|
        opts[k.to_s] = v
      end
      recv
    end
  end

end

