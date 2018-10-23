require 'sinatra'
require 'pry'
require_relative 'techacademy'

def techacademy
  @techacademy ||= Techacademy.new(ENV['TECHACADEMY_EMAIL'], ENV['TECHACADEMY_PASSWORD'])
end

before do
  @errors = []
end

get '/' do
  erb :top
end

get '/find_user' do
  if techacademy.find_user(params[:name])
    @table = techacademy.schedules
    erb :schedule
  else
    @name = params[:name]
    @errors << techacademy.error
    erb :top
  end
end

get '/calendars/:year/:month' do
  @calendar = techacademy.calendar(params[:year], params[:month])
  erb :calendar
end

get '/appointments/:id/edit' do
end

