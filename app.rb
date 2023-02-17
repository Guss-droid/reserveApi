require 'sinatra'
require 'bcrypt'
require 'jwt'
require 'dotenv'
require_relative 'database'
require 'date'

Dotenv.load

class AuthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    auth_header = env['HTTP_AUTHORIZATION']
    token = auth_header.split(' ')[1] if auth_header

    begin
      payload = JWT.decode(token, ENV['JWT_SECRET'], true, algorithm: 'HS256')
      env['jwt.payload'] = payload
    rescue JWT::ExpiredSignature
      [401, {'Content-Type' => 'application/json'}, ['Expired token']]
    rescue JWT::DecodeError
      [401, {'Content-Type' => 'application/json'}, ['Invalid token']]
    end

    @app.call(env)
  end
end

def login(email, password)
  user = CONN.exec_params('select * from users where email = $1', [email]).first

  if user && BCrypt::Password.new(user['password']) == password
    payload = {user_id: user['id'], email: email}
    token = JWT.encode(payload, ENV['JWT_SECRET'], 'HS256')
    return {message: token}.to_json
  end

  {message: 'Invalid email or password'}.to_json
end

before '/hotels' do
  halt 401, {'Content-Type' => 'application/json'}, {message: 'Unauthorized'} unless env['jwt.payload']
end

post '/create/users' do
  data = JSON.parse request.body.read
  email, name, password = data['email'], data['name'], data['password']
  userAlreadyExists = false
  message = 'User created successfully'

  CONN.exec_params('select * from users where email = $1', [email]) do |result|
    result.each do |row|
      userAlreadyExists = true
    end
  end

  hashed_password = BCrypt::Password.create(password)

  if !userAlreadyExists
    CONN.exec_params(
      'insert into users (email, name, password) values ($1, $2, $3)',
      [email, name, hashed_password]
    )
  end

  if userAlreadyExists
    message = 'User already exists'
  end

  {message: message}.to_json
end

post '/login' do
  data = JSON.parse request.body.read
  email, password = data['email'], data['password']

  login(email, password)
end

get '/hotels' do
  hotels = []
  CONN.exec('select * from hotels') do |result|
    result.each do |row|
      hotels << row
    end
  end

  {message: hotels}.to_json
end

post '/hotels' do
  data = JSON.parse request.body.read
  name, rooms = data['name'], data['rooms']

  CONN.exec_params('insert into hotels (name, rooms) values ($1, $2)', [name, rooms])

  {message: 'Hotel created successfully'}.to_json
end

put '/hotels/rate/:id' do
  data = JSON.parse request.body.read
  rate, id, user = data['rate'], params['id'], env['jwt.payload']

  notes = []
  total_rate, total_note, id_rate = 0
  userAlreadyAvailed = false
  message = 'Successfully availed'

  CONN.exec_params('select * from ratings where user_id = $1 and hotel_id = $2', [user[0]['user_id'], id]) do |result|
    if result.count != 0
      userAlreadyAvailed = true

      result.each do |row|
        id_rate = row['id']
      end
    end
  end

  if !userAlreadyAvailed
    CONN.exec_params('insert into ratings (note, user_id, hotel_id) values ($1, $2, $3)', [rate, user[0]['user_id'], id])
  else
    CONN.exec_params('update ratings set note = $1 where id = $2', [rate, id_rate])
    message = 'Note updated successfully'
  end

  CONN.exec_params('select * from ratings where hotel_id = $1', [id]) do |result|
    total_rate = result.count if result.count != 0
    result.each do |row|
      notes << {note: row['note']}
    end
  end

  notes_sum = notes.inject(0) { |sum, note| sum + note[:note].to_i }
  average = notes_sum.to_f / total_rate

  CONN.exec_params('update hotels set total_note = $1 where id = $2', [average, id])

  {message: message}.to_json
end

get '/hotels/rate' do
  rates = []
  CONN.exec('select * from ratings') do |result|
    result.each do |row|
      rates << row
    end
  end

  {message: rates}.to_json
end

delete '/hotels/delete/note/:id' do
  id, user = params['id'], env['jwt.payload']

  CONN.exec_params('delete from ratings where id = $1 and user_id = $2', [id, user[0]['user_id']])

  {message: 'Deleted successfully'}.to_json
end

post '/hotels/reserve/:id' do
  data = JSON.parse request.body.read
  c_in, c_out, id, user = data['check_in'], data['check_out'], params['id'], env['jwt.payload']
  user_id, message, today = user[0]['user_id'], 'Reserve created successfully', Date.today
  rooms = 0

  CONN.exec_params('select * from hotels where id = $1', [id]) do |result|
    result.each do |row|
      rooms = row['rooms'].to_i
    end
  end

  CONN.exec_params('select * from reserves where hotel_id = $1 and check_out < current_date', [id]) do |result|
    result.each do |row|
      rooms += 1
    end
  end

  if Date.parse(c_in) < Date.parse(c_out) && Date.parse(c_in) > today
    CONN.transaction do
      CONN.exec_params('select * from reserves where hotel_id = $1 and check_in <= $2 and check_out >= $3', [id, c_out, c_in]) do |result|
        available_rooms = rooms

        if available_rooms > 0
          CONN.exec_params('insert into reserves (check_in, check_out, user_id, hotel_id) values ($1, $2, $3, $4)', [c_in, c_out, user_id, id])
          CONN.exec_params('update hotels set rooms = $1 where id = $2', [rooms - 1, id])
        else
          message = 'No rooms available for the selected date'
        end
      end
    end
  elsif Date.parse(c_in) > Date.parse(c_out)
    message = 'Invalid check-in and check-out dates'
  else
    message = 'Check-in date cannot be before today'
  end

  {message: message}.to_json
end

get '/hotels/reserve' do
  reserves = []

  CONN.exec('select * from reserves') do |result|
    result.each do |row|
      reserves << row
    end
  end

  {message: reserves}.to_json
end

delete '/hotels/delete/reserve/:id' do
  id, user = params['id'], env['jwt.payload']
  rooms = 0

  CONN.exec_params('delete from reserves where hotel_id = $1 and user_id = $2', [id, user[0]['user_id']])

  CONN.exec_params('select * from hotels where id = $1', [id]) do |result|
    result.each do |row|
      rooms = row['rooms']
    end
  end

  CONN.exec_params('update hotels set rooms = $1 where id = $2', [rooms.to_i + 1, id])

  {message: 'Deleted successfully'}.to_json
end

delete '/hotels/delete/hotel/:id' do
  id = params['id']

  CONN.exec_params('delete from hotels where id = $1 ', [id])

  {message: 'Deleted successfully'}.to_json
end

use AuthMiddleware
