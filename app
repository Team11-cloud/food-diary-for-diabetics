from flask import Flask, render_template, redirect, url_for, flash, request, jsonify
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from models import db, User, Product, Meal, MealItem, GlucoseRecord
from forms import RegistrationForm, LoginForm, ProductForm, MealForm, FoodEntryForm, GlucoseForm
from datetime import datetime, date
import re

app = Flask(__name__)
app.config['SECRET_KEY'] = 'ваш-секретный-ключ'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///diabetic_diary.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db.init_app(app)

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'
login_manager.login_message = 'Сначала войди в аккаунт'
login_manager.login_message_category = 'warning'


@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))


def is_email(identifier):
    p = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    return re.match(p, identifier) is not None


def is_phone(identifier):
    p = r'^\+?[1-9]\d{1,14}$'
    s = identifier.replace(' ', '').replace('-', '').replace('(', '').replace(')', '')
    return re.match(p, s) is not None


@app.route('/')
def index():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    return render_template('index.html')


@app.route('/register', methods=['GET', 'POST'])
def register():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))

    form = RegistrationForm()

    if form.validate_on_submit():
        email = form.email.data.strip() if form.email.data else None
        phone = form.phone.data.strip() if form.phone.data else None
        name = form.name.data.strip()

        if email and User.query.filter_by(email=email).first():
            flash('Пользователь с таким email уже существует', 'danger')
            return redirect(url_for('register'))

        if phone and User.query.filter_by(phone=phone).first():
            flash('Пользователь с таким телефоном уже существует', 'danger')
            return redirect(url_for('register'))

        user = User(
            email=email,
            phone=phone,
            name=name,
            diabetes_type=int(form.diabetes_type.data)
        )
        user.set_password(form.password.data)

        db.session.add(user)
        db.session.commit()

        flash('Регистрация успешна! Теперь войди в аккаунт.', 'success')
        return redirect(url_for('login'))

    return render_template('register.html', form=form)


@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))

    form = LoginForm()

    if form.validate_on_submit():
        identifier = form.email_or_phone.data.strip()
        user = None

        if is_email(identifier):
            user = User.query.filter_by(email=identifier).first()
        elif is_phone(identifier):
            user = User.query.filter_by(phone=identifier).first()
        else:
            user = User.query.filter(
                (User.email == identifier) | (User.phone == identifier)
            ).first()

        if user and user.check_password(form.password.data):
            login_user(user)
            next_page = request.args.get('next')
            return redirect(next_page or url_for('dashboard'))

        flash('Неверный email/телефон или пароль', 'danger')

    return render_template('login.html', form=form)


@app.route('/logout')
@login_required
def logout():
    logout_user()
    flash('Ты вышел из аккаунта', 'info')
    return redirect(url_for('index'))


@app.route('/dashboard')
@login_required
def dashboard():
    today = date.today()

    meals = Meal.query.filter_by(
        user_id=current_user.id,
        date=today
    ).order_by(Meal.time).all()

    total_calories = sum(meal.total_calories for meal in meals)
    total_carbs = sum(meal.total_carbs for meal in meals)
    total_xe = sum(meal.total_xe for meal in meals)

    glucose_records = GlucoseRecord.query.filter_by(
        user_id=current_user.id
    ).order_by(GlucoseRecord.created_at.desc()).limit(5).all()

    return render_template(
        'dashboard.html',
        meals=meals,
        total_calories=total_calories,
        total_carbs=total_carbs,
        total_xe=total_xe,
        glucose_records=glucose_records,
        today=today
    )


@app.route('/add_meal', methods=['GET', 'POST'])
@login_required
def add_meal():
    form = MealForm()

    if request.method == 'GET':
        form.date.data = date.today()
        form.time.data = datetime.now().time().replace(second=0, microsecond=0)

    if form.validate_on_submit():
        meal = Meal(
            user_id=current_user.id,
            meal_type=form.meal_type.data,
            date=form.date.data,
            time=form.time.data,
            notes=form.notes.data
        )
        db.session.add(meal)
        db.session.commit()

        flash('Прием пищи создан. Теперь добавь продукты.', 'success')
        return redirect(url_for('add_food', meal_id=meal.id))

    return render_template('add_meal.html', form=form)


@app.route('/add_food/<int:meal_id>', methods=['GET', 'POST'])
@login_required
def add_food(meal_id):
    meal = Meal.query.get_or_404(meal_id)

    if meal.user_id != current_user.id:
        flash('Доступ запрещен', 'danger')
        return redirect(url_for('dashboard'))

    form = FoodEntryForm()

    if form.validate_on_submit():
        product_name = form.product_name.data.strip()
        weight = form.weight.data

        product = Product.query.filter(
            Product.name.ilike(f'%{product_name}%')
        ).first()

        if product:
            item = MealItem(
                meal_id=meal.id,
                product_id=product.id,
                weight=weight
            )
            db.session.add(item)
            db.session.commit()

            flash('Продукт добавлен', 'success')
            return redirect(url_for('add_food', meal_id=meal.id))

        return redirect(url_for(
            'add_product',
            meal_id=meal.id,
            product_name=product_name,
            weight=weight
        ))

    query = request.args.get('q', '').strip()
    products = []

    if query:
        products = Product.query.filter(
            Product.name.ilike(f'%{query}%')
        ).limit(10).all()

    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return jsonify([{'id': p.id, 'name': p.name} for p in products])

    return render_template(
        'add_food.html',
        form=form,
        meal=meal,
        products=products
    )


@app.route('/add_product', methods=['GET', 'POST'])
@login_required
def add_product():
    if request.method == 'POST':
        meal_id = request.form.get('meal_id')
        weight = request.form.get('weight')
        product_name = request.form.get('name')
    else:
        meal_id = request.args.get('meal_id')
        weight = request.args.get('weight')
        product_name = request.args.get('product_name')

    form = ProductForm()

    if request.method == 'GET' and product_name:
        form.name.data = product_name

    if form.validate_on_submit():
        existing = Product.query.filter(
            Product.name.ilike(form.name.data.strip())
        ).first()

        if existing:
            flash('Такой продукт уже есть в базе', 'warning')
            return redirect(url_for('add_food', meal_id=meal_id) if meal_id else url_for('dashboard'))

        product = Product(
            name=form.name.data.strip(),
            calories=form.calories.data,
            proteins=form.proteins.data,
            fats=form.fats.data,
            carbs=form.carbs.data,
            sugar=form.sugar.data,
            fiber=form.fiber.data or 0,
            created_by=current_user.id
        )
        db.session.add(product)
        db.session.commit()

        if meal_id and weight:
            meal = Meal.query.get(int(meal_id))
            if meal and meal.user_id == current_user.id:
                item = MealItem(
                    meal_id=meal.id,
                    product_id=product.id,
                    weight=float(weight)
                )
                db.session.add(item)
                db.session.commit()

                flash('Продукт создан и добавлен в прием пищи', 'success')
                return redirect(url_for('add_food', meal_id=meal.id))

        flash('Продукт добавлен в базу', 'success')
        return redirect(url_for('dashboard'))

    return render_template(
        'add_product.html',
        form=form,
        meal_id=meal_id,
        weight=weight
    )


@app.route('/history')
@login_required
def history():
    page = request.args.get('page', 1, type=int)
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    q = Meal.query.filter_by(user_id=current_user.id)

    if start_date:
        q = q.filter(Meal.date >= datetime.strptime(start_date, '%Y-%m-%d').date())

    if end_date:
        q = q.filter(Meal.date <= datetime.strptime(end_date, '%Y-%m-%d').date())

    meals = q.order_by(Meal.date.desc(), Meal.time.desc()).paginate(
        page=page,
        per_page=10,
        error_out=False
    )

    return render_template('history.html', meals=meals)


@app.route('/add_glucose', methods=['GET', 'POST'])
@login_required
def add_glucose():
    form = GlucoseForm()

    if form.validate_on_submit():
        record = GlucoseRecord(
            user_id=current_user.id,
            value=form.value.data,
            measurement_type=form.measurement_type.data,
            notes=form.notes.data
        )
        db.session.add(record)
        db.session.commit()

        flash('Запись о глюкозе сохранена', 'success')
        return redirect(url_for('dashboard'))

    return render_template('add_glucose.html', form=form)


@app.route('/api/products')
@login_required
def api_products():
    query = request.args.get('q', '').strip()

    products = Product.query.filter(
        Product.name.ilike(f'%{query}%')
    ).limit(20).all()

    return jsonify([
        {
            'id': p.id,
            'name': p.name,
            'calories': p.calories,
            'carbs': p.carbs,
            'sugar': p.sugar
        }
        for p in products
    ])


@app.route('/profile')
@login_required
def profile():
    return render_template('profile.html')


if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(debug=True)
