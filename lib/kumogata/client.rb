class Kumogata::Client
  def initialize(options)
    @options = options
    @cloud_formation = AWS::CloudFormation.new
  end

  def create(path_or_url, stack_name = nil)
    template = open_template(path_or_url)

    if @options.delete_stack?
      template['Resources'].each do |k, v|
        v['DeletionPolicy'] = 'Retain'
      end
    end

    create_stack(template, stack_name)
  end

  def validate(path_or_url)
    template = open_template(path_or_url)
    validate_template(template)
  end

  def convert(path_or_url)
    template = open_template(path_or_url)

    if ruby_template?(path_or_url)
      puts JSON.pretty_generate(template)
    else
      puts devaluate_template(template)
    end
  end

  def update(path_or_url, stack_name)
    template = open(path_or_url) do |f|
      evaluate_template(f)
    end

    update_stack(template, stack_name)
  end

  def delete(stack_name)
    if @options.force? or agree("Aare you sure you want to delete `#{stack_name}`? ".yellow)
      delete_stack(stack_name)
    end
  end

  def list(stack_name = nil)
    stacks = describe_stacks(stack_name)
    puts JSON.pretty_generate(stacks)
  end

  private

  def open_template(path_or_url)
    open(path_or_url) do |f|
      if ruby_template?(path_or_url)
        evaluate_template(f)
      else
        JSON.parse(f.read)
      end
    end
  end

  def ruby_template?(path_or_url)
    File.extname(path_or_url) == '.rb'
  end

  def evaluate_template(template)
    key_converter = proc do |key|
      key = key.to_s
      key.gsub!('__', '::') if @options.replace_underscore?
      key
    end

    value_converter = proc {|v| v.to_s }

    Dslh.eval(template.read, {
      :key_conv   => key_converter,
      :value_conv => value_converter,
      :scope_hook => method(:define_template_func),
      :filename   => template.path,
    })
  end

  def devaluate_template(template)
    key_conv = proc do |k|
      k.to_s.gsub('::', '__')
    end

    # XXX:
    #exclude_key = proc do |k|
    #  k = k.to_s.gsub('::', '__')
    #  k !~ /\A[_a-z]\w+\Z/i and k !~ %r|(?:/[:graph:]+)+|
    #end
    #
    #key_conv = proc do |k|
    #  k = k.to_s
    #
    #  if k =~ %r|(?:/[:graph:]+)+|
    #    proc do |v, nested|
    #      if nested
    #        "_path(#{k.inspect}) #{v}"
    #      else
    #        "_path #{k.inspect}, #{v}"
    #      end
    #    end
    #  else
    #    k.gsub('::', '__')
    #  end
    #end

    Dslh.deval(template, :key_conv => key_conv)
  end

  def define_template_func(scope)
    # XXX: Add _path()
    scope.instance_eval do
      def user_data(data)
        data.strip_lines.encode64
      end
    end
  end

  def describe_stacks(stack_name)
    AWS.memoize do
      stacks = @cloud_formation.stacks
      stacks = stacks.select {|i| i.name == stack_name } if stack_name

      stacks.map do |stack|
        {
          'StackName'    => stack.name,
          'CreationTime' => stack.creation_time,
          'StackStatus'  => stack.status,
          'Description'  => stack.description,
        }
      end
    end
  end

  def create_stack(template, stack_name)
    stack_name = stack_name || 'kumogata-' + UUIDTools::UUID.timestamp_create

    Kumogata.logger.info("Creating stack: #{stack_name}".cyan)
    stack = @cloud_formation.stacks.create(stack_name, template.to_json, build_create_options)

    unless while_in_progress(stack, 'CREATE_COMPLETE')
      errmsgs = ['Create failed']
      errmsgs << stack_name
      errmsgs << sstack.tatus_reason if stack.status_reason
      raise errmsgs.join(': ')
    end

    if @options.delete_stack?
      Kumogata.logger.info("Delete stack: #{stack.name}".yellow)
      stack.delete
    end
  end

  def update_stack(template, stack_name)
    stack = @cloud_formation.stacks[stack_name]
    stack.status
    stack.update(build_update_options(template.to_json))

    Kumogata.logger.info("Updating stack: #{stack_name}")

    unless while_in_progress(stack, 'UPDATE_COMPLETE')
      errmsgs = ['Update failed']
      errmsgs << stack_name
      errmsgs << sstack.tatus_reason if stack.status_reason
      raise errmsgs.join(': ')
    end
  end

  def delete_stack(stack_name)
    stack = @cloud_formation.stacks[stack_name]
    stack.status

    Kumogata.logger.info("Deleting stack: #{stack_name}")
    stack.delete

    completed = false

    begin
      completed = while_in_progress(stack, 'DELETE_COMPLETE')
    rescue AWS::CloudFormation::Errors::ValidationError
      # Handle `Stack does not exist`
      completed = true
      Kumogata.logger.info('Successfully')
    end

    unless completed
      errmsgs = ['Delete failed']
      errmsgs << stack_name
      errmsgs << sstack.tatus_reason if stack.status_reason
      raise errmsgs.join(': ')
    end
  end

  def while_in_progress(stack, complete_status)
    while stack.status =~ /_IN_PROGRESS\Z/
      print '.'.intense_black unless @options.debug?
      sleep 1
    end

    completed = (stack.status == complete_status)
    Kumogata.logger.info(completed ? 'Successfully' : 'Failed')
    return completed
  end

  def build_create_options
    opts = {}
    add_parameters(opts)

    [:capabilities, :disable_rollback, :notify, :timeout].each do |k|
      opts[k] = @options[k] if @options[k]
    end

    return opts
  end

  def build_update_options(template)
    opts = {:template => template}
    add_parameters(opts)
    return opts
  end

  def add_parameters(hash)
    if @options.parameters?
      parameters = {}

      @options.parameters.each do |i|
        key, value = i.split('=', 2)
        parameters[key] = value
      end

      hash[:parameters] = parameters
    end
  end

  def validate_template(template)
    result = @cloud_formation.validate_template(template.to_json)

    if result[:code]
      raise result.values_at(:code, :message).join(': ')
    end

    Kumogata.logger.info('Template validated successfully'.green)
  end
end
