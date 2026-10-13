class CreateRoles < ActiveRecord::Migration[8.1]
  def up
    create_table :roles do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.boolean :system, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :roles, :key, unique: true
    add_index :roles, "lower(name)", unique: true, name: "index_roles_on_lower_name"

    create_table :role_permissions do |t|
      t.references :role, null: false, foreign_key: true
      t.string :resource, null: false
      t.string :ability, null: false
      t.timestamps
    end
    add_index :role_permissions, [ :role_id, :resource, :ability ], unique: true, name: "index_role_permissions_on_role_resource_ability"
    add_check_constraint :role_permissions, "ability IN ('read', 'manage')", name: "role_permissions_ability_check"

    Role.reset_column_information
    RolePermission.reset_column_information
    Role.seed_defaults!

    add_index :users, :role
    add_foreign_key :users, :roles, column: :role, primary_key: :key, name: "fk_users_role"
    remove_check_constraint :users, name: "users_role_check"
  end

  def down
    remove_foreign_key :users, name: "fk_users_role"
    remove_index :users, :role
    execute <<~SQL.squish
      UPDATE users SET role = 'viewer'
      WHERE role NOT IN ('admin', 'operator', 'viewer')
    SQL
    add_check_constraint :users,
      "role IN ('admin', 'operator', 'viewer')",
      name: "users_role_check"
    drop_table :role_permissions
    drop_table :roles
  end
end
