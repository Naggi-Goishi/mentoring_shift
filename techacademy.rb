require 'mechanize'
require 'uri'

module TechacademyHelper
  def self.included cls
    cls.extend self
  end

  def jp_time_now
    Time.now.utc.localtime('+09:00')
  end

  def minites(min)
    min * 60
  end

  def days(day)
    day * 60 * 60 * 24
  end

  def first_wday_of_in_jst(year, month)
    (Time.new(year, month, 1, 0, 0, 0, '+09:00').wday - 1) % 7
  end

  def tzoffset_to_japan
    9 * 60 * 60 - Time.new.utc_offset
  end

  def tzoffset_to_japan_in_hour
    tzoffset_to_japan / 60 / 60
  end
end

class Techacademy
  BASE_URL = 'https://techacademy.jp'

  attr_reader :error

  include TechacademyHelper

  def initialize(email, password)
    @agent = Mechanize.new
    @email = email
    @password = password

    login
  end

  def login
    page = @agent.get('https://techacademy.jp/mentor/login')
    form = page.form
    form['session[email]']    = @email
    form['session[password]'] = @password

    @agent.submit(form)
  end

  def calendar(year, month)
    page = get("/mentor/schedule/appointments/#{year}/#{month}")
    calendar = Calendar.new(year, month)

    page.parser.search('table tr').drop(1).map do |tr|
      datetime_match = tr.children[0].text.match(/(\d*)\/(\d*) \(.\)(\d*):(\d*)~(\d*):(\d*)/)[1..4]
      calendar << Appointment.new(year.to_i, *datetime_match.map(&:to_i))
    end

    calendar
  end

  def schedules(user_id=nil)
    @user_id ||= user_id

    page = get('/mentor/users/' + @user_id + '/schedule')

    page.parser.search('table tr').map do |tr|
      edit_disabled = ''

      if tr.search('span').text.include? 'キャンセル'
        edit_disabled = 'disabled'
        tr_html = "<tr class='table-warning'>"
      elsif tr.search('span').text.include? '実施済'
        edit_disabled = 'disabled'
        tr_html = "<tr class='table-success'>"
      elsif tr.search('span').text.include? '未実施'
        tr_html = "<tr>"
      else
        tr_html = "<thead class='thead-dark'><tr>"
        tr.children.each { |td| tr_html += "<th>#{td.text}</th>" }
        next tr_html += "</tr></thead>"
      end

      tr.children.each do |td|
        if (a = td.at('a'))
          appointment_id = '#'
          if appointment_match = a.attribute('href').value.match(/\/mentor\/appointments\/(\d+)\/edit\z/)
            appointment_id = appointment_match[1]
          end

          tr_html += "<td><a class='btn btn-outline-info #{edit_disabled}' href='/calendars/#{jp_time_now.year}/#{jp_time_now.month}'>予約変更</a></td>"
        else
          tr_html += "<td>#{td.text}</td>"
        end
      end

      tr_html += '</tr>'
    end
  end

  def find_user(name, reload=false)
    return @user_id if @user_id

    page = get('/mentor/users/search', { 'q[full_name_or_full_name_with_space_or_slack_name_cont]' => name })
    user_id_regex = /\/mentor\/users\/(\d+)\z/
    links = page.links.select { |link| link.href.match? user_id_regex }

    if links.length == 1
      @user_id = links[0].href.match(user_id_regex)[1]
      true
    elsif links.length > 1
      @error = Error.new(:user_multiple_hits)
      false
    else
      @error = Error.new(:user_not_found, name)
      false
    end
  end

  private
  def get(end_point, params={})
    if params.empty?
      @agent.get(BASE_URL + end_point)
    else
      @agent.get(BASE_URL + end_point + '?' + URI.encode_www_form(params))
    end
  end
end

# All timezone except SHIFT is in JST
class Techacademy::Calendar
  # Sunday 0 .. Saturday 6 in local time due to day light saving
  SHIFT = [
    { start: '21:00', end: '24:00' },
    { start: '21:00', end: '24:00' },
    { start: '21:30', end: '24:00' },
    { start: '21:00', end: '24:00' },
    { start: '21:30', end: '24:00' },
    { start: '21:00', end: '24:00' },
    { start: '21:00', end: '24:00' }
  ]

  include TechacademyHelper

  attr_accessor :appointments

  class << self
    def shift_start(year, month, day)
      jp_time = Time.new(year, month, day, 0, 0, 0, '+09:00')
      shift_start_h, shift_start_m = SHIFT[jp_time.wday][:start].split(':').map(&:to_i)
      shift_start_h += tzoffset_to_japan_in_hour

      if shift_start_h > 24
        Time.new(year, month, day, shift_start_h - 24, shift_start_m, 0) - days(1)
      elsif shift_start_h < 0
        Time.new(year, month, day, shift_start_h + 24, shift_start_m, 0) + days(1)
      else
        Time.new(year, month, day, shift_start_h, shift_start_m, 0)
      end
    end

    def shift_end(year, month, day)
      jp_time = Time.new(year, month, day, 0, 0, 0, '+09:00')
      shift_end_h, shift_end_m = SHIFT[jp_time.wday][:end].split(':').map(&:to_i)
      shift_end_h += tzoffset_to_japan_in_hour

      if shift_end_h > 24
        Time.new(year, month, day, shift_end_h - 24, shift_end_m, 0) - days(1)
      elsif shift_end_h < 0
        Time.new(year, month, day, shift_end_h + 24, shift_end_m, 0) + days(1)
      else
        Time.new(year, month, day, shift_end_h, shift_end_m, 0)
      end
    end
  end

  def initialize(year, month)
    @year         = year
    @month        = month
    @appointments = []
    @appointments_count = {}
  end

  def header
    <<~HTML
      <thead class='thead-dark'>
        <tr>
          <th>月</th>
          <th>火</th>
          <th>水</th>
          <th>木</th>
          <th>金</th>
          <th>土</th>
          <th>日</th>
        </tr>
      </thead>
    HTML
  end

  def body
    rows = []
    wday = first_wday_of_in_jst(@year, @month)
    @appointments.each_with_index do |appointment, i|
      if i < wday
        rows << "<tr><td class='prev-month calendar-day'></td></tr>"
      else
        tr += "<a href='#{appointment.edit_path}'><td class='calendar-day'></td></a>"
        rows << (tr += '</tr>') if appointment.wday
      end
    end
  end

  def <<(appointment)
    if @appointments_count.key?(appointment.day)
      @appointments_count[appointment.day] += 1
    else
      @appointments_count[appointment.day] = 1
    end

    @appointments << appointment
  end

  def full?(day)
    full_count =< @appointments_count[day]
  end

  def almost_full?(day, percent=80)
    (full_count * percent / 100) =< @appointments_count[day]
  end

  def add_appointment_in_shift(appointment)
    if appointment.in_shift?
      @appointments << appointment
      true
    else
      false
    end
  end

  private
  def full_count
    hours = (Techacademy::Calendar.shift_end(@year, @month, day) - Techacademy::Calendar.shift_start(@year, @month, day)) / 60 / 60
    hours / 0.5
  end
end

class Techacademy::Appointment
  attr_reader :start_dt, :end_dt, :day, :id

  include TechacademyHelper

  def initialize(id, year, month, day, start_h, start_m)
    @id       = id
    @year     = year
    @month    = month
    @day      = day
    @start_dt = Time.new(year, month, day, start_h, start_m, 0, '+09:00')
    @end_dt   = Time.new(year, month, day, start_h, start_m, 0, '+09:00') + minites(30)
    @wday     = (@start_dt.wday - 1) % 7
  end

  def edit_path
    "appointments/#{@id}/edit"
  end

  def in_shift?
    shift_start = Techacademy::Calendar.shift_start(@start_dt.year, @start_dt.month, @start_dt.day)
    shift_end   = Techacademy::Calendar.shift_end(@end_dt.year, @end_dt.month, @end_dt.day)

    (shift_start <= @start_dt && @end_dt <= shift_end) ? true : false
  end
end

class Techacademy::Error
  MESSAGES = {
    user_multiple_hits: '複数のユーザーが見つかりました。フルネームでお試しください。',
    user_not_found:     '%s というユーザーがみつかりませんでした。'
  }

  def initialize(name, username=nil)
    raise Exception.new('user not found error must have username argument') if name == :user_not_found && username.nil?
    @name = name
    @username = username
  end

  def message
    MESSAGES[@name] % @username
  end
end
